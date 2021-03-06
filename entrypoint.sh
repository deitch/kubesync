#!/bin/sh
set -e

[ -n "$DEBUG" ] && set -x

log() {
  echo "$(date -R -u): $1"
}

runcmd() {
  local cmd="$1"
  shift
  local args="$@"
  set -- $cmd
  IFS=$'\n'
  for i in $( printf " %s" ${args} | xargs printf "%s\n" ); do
    set -- "$@" "$i"
  done
  "$@"
}

genrole() {
  local namespace="$1"
  cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kubesync
  namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
- kind: User
  name: kubesync-limited
  apiGroup: rbac.authorization.k8s.io
EOF
}

getconfig() {
  local configurl="$1"
  local configpath=
  local config=

  # the config file could be one of several types
  case $configurl in
    /*)
      # does it exist?
      if [ ! -e ${configurl} ]; then
        log "FATAL: Config file ${configurl} does not exist, exiting" >&2
        exit 1
      fi
      config=$(cat ${configurl})
      ;;
    file://*)
      configpath=${configurl##file://}
      # does it exist?
      if [ ! -e ${configpath} ]; then
        log "FATAL: Config file ${configurl} does not exist, exiting" >&2
        exit 1
      fi
      config=$(cat ${configpath})
      ;;
    http://*|https://*)
      set +e
      config=$(runcmd curl $CURL_OPTIONS -L ${configurl} )
      result=$?
      set -e
      if [ $result -ne 0 ]; then
        log "FATAL: Could not retrieve config from url ${configurl}, exiting" >&2
        exit 1
      fi
      ;;
    *)
      echo "FATAL: Unknown config file format in env var CONFIG: $configurl">&2
      exit 1
      ;;
  esac
  
  if [ -z "${config}" ]; then
    echo "FATAL: config at ${configurl} is empty" >&2
    exit 1
  fi

  # convert to json for advanced processing
  json=$(echo ${config} | yq r -j - )
  
  # it must be an array or error out - but do not actually output the result, just catch the error code
  set +e
  echo $json | jq -e '. | type == "array"' >/dev/null
  result=$?
  set -e
  if [ $result -ne 0 ]; then
    log "FATAL: Config file does not contain array, exiting" >&2
    exit 1
  fi

  echo ${json}
}

repotodir() {
  local url=$1
  reponame=$(basename $url)
  reponame=${reponame%%.*git}
  echo $reponame
}

getrepo() {
  local url=$1
  local gdir=$2

  # get the name of the repo, but be sure to remove .git off the end if it exists
  reponame=$(repotodir $url)

  local targetdir=$gdir/$reponame
  local tmpoutdir=$outdir/$reponame
  log "INFO: cloning $url into $targetdir"
  git clone $url $targetdir
}

update_repo() {
  repo=$(basename $PWD)
  # make sure it is up to date
  log "INFO: updating from $repo"
  # always update the origin
  git remote update origin --prune
}

validate_privileged() {
  local privileged="$1"
  local ymldir="$2"
  local errors=
  local json=

  # if we are privileged, then it is valid
  if [ "$privileged" = "true" ]; then
    return
  fi

  # check each file in the dir that it has none of the privileged behaviours
  for i in $ymldir/*; do
    # we care only about yml and json files
    case $i in
      *.yml|*.yaml)
        json=$(cat $i | yq r -j -d'*' -)
        ;;
      *.json)
        # just take contents, but wrap in array if it is not already
        json=$(cat $i | jq 'if type=="array" then . else [.] end')
        ;;
      *)
        continue
        ;;
    esac
    
    # process the content of the json
    # three possibilities:
    #  1- it is a `Kind: List`, which contains `items: []` array
    #  2- it is a single document in a file
    #  3- it is multiple documents in a file, separated by `---`
    # since we passed all through `yq -d'*' -r`, it will be an array, where we can check each item. This merges 2&3 above.
    #   we then check if `Kind=List`, and if so, process `items` array iteratively
    # samples of each:
    # - `Kind:List`: [{"apiVersion":"v1","items":[{"apiVersion":"v1","kind":"Service","metadata":{"name":"list-service-test"},"spec":{"ports":[{"port":80,"protocol":"TCP"}],"selector":{"app":"list-deployment-test"}}},{"apiVersion":"extensions/v1beta1","kind":"Deployment","metadata":{"labels":{"app":"list-deployment-test"},"name":"list-deployment-test"},"spec":{"replicas":1,"template":{"metadata":{"labels":{"app":"list-deployment-test"}},"spec":{"containers":[{"image":"nginx","name":"nginx"}]}}}}],"kind":"List"}]
    # - Single doc: [{"apiVersion":"v1","kind":"Service","metadata":{"name":"list-service-test"},"spec":{"ports":[{"port":80,"protocol":"TCP"}],"selector":{"app":"list-deployment-test"}}}]
    # - Multiple docs: [{"apiVersion":"v1","kind":"Service","metadata":{"name":"list-service-test"},"spec":{"ports":[{"port":80,"protocol":"TCP"}],"selector":{"app":"list-deployment-test"}}},{"apiVersion":"extensions/v1beta1","kind":"Deployment","metadata":{"labels":{"app":"list-deployment-test"},"name":"list-deployment-test"},"spec":{"replicas":1,"template":{"metadata":{"labels":{"app":"list-deployment-test"}},"spec":{"containers":[{"image":"nginx","name":"nginx"}]}}}}]
    
    # everything is an array, so loop through elements
    for elm in $(echo "$json" | jq -c '.[]' ); do
      needs_privilege=$(check_privileged "$elm")
      if [ -n "$needs_privilege" ]; then
        errors="$errors $i"
      fi
    done 
  done
  
  # did we find any?
  if [ -n "$errors" ]; then
    return 1
  fi

  return
}

# check if a json has elements that need privilege
check_privileged() {
  local json="$1"
  if [ -z "$json" ]; then
    return
  fi

  # now process the info
  # if it is an array, call ourselves recursively
  local jsontype=$(echo "$json" | jq -r 'type')
  local kind=$(echo "$json" | jq -r '.Kind')
  if [ "$jsontype" = "array" ]; then
    for elm in $(echo "$json" | jq -c '.[]' ); do
      needs_privilege=$(check_privileged "$elm")
      if [ -n "$needs_privilege" ]; then
        echo "$needs_privilege"
        return
      fi
    done
  elif [ "$kind" = "List" ]; then
    for elm in $(echo "$json" | jq '.items[]' ); do
      needs_privilege=$(check_privileged "$elm")
      if [ -n "$needs_privilege" ]; then
        echo "$needs_privilege"
        return
      fi
    done
  else
    # we have a single item, so check its privilege
    local hostnet=$(echo "$json" | jq -r '.. | .hostNetwork? | select(type != "null")')
    local namespace=$(echo "$json" | jq -r '.metadata.namespace')
    if [ "$hostnet" = "true" ]; then
      echo "hostNetwork"
      return
    fi
    if [ "$namespace" = "kube-system" ]; then
      echo "namespace"
      return
    fi
  fi
}

checkout_version() {
  local versiontype=$1
  local versiondetail=$2

  set +e

  # do we add debugging info?
  if [ -n "$DEBUG" ]; then
    log "DEBUG: PWD is $PWD"
    git branch --list
    git --no-pager log
  fi

  # in all cases, we are assuming we have commits and files. What if we don't? We should handle it sanely.
  case "$versiontype" in
  branch)
    git checkout $versiondetail --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout branch $versiondetail, might not exist yet or have any files"
      return 1
    fi
    git pull origin $versiondetail --tags
    commit=$(git log --oneline --pretty=tformat:"%H" | head -1)
    log "INFO: updating from latest commit ${commit} on branch $versiondetail"
    ;;
  commit)
    git checkout master --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout branch master, might not exist yet or have any files"
      return 1
    fi
    git pull origin master --tags
    git checkout $versiondetail --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout commit $versiondetail, might not exist yet or have any files"
      return 1
    fi
    log "INFO: updating from specific commit ${versiondetail}"
    ;;
  tag)
    git checkout master --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout branch master, might not exist yet or have any files"
      return 1
    fi
    git pull origin master --tags
    commit=
    if [ "$versiondetail" = "latest" ]; then
      commitandtag=$(git for-each-ref --format='%(*committerdate:raw)%(committerdate:raw) %(refname) %(*objectname) %(objectname)' refs/tags | sort -n | awk '{ print $4, $3; }' | tail -1)
      tag=${commitandtag##* }
      tag=${tag##*/}
      commit=${commitandtag%% *}
      log "INFO: tag:latest set, updating from latest tag ${tag} commit ${commit}"
    else
      commit=$(git rev-list -n 1 ${versiondetail})
      log "INFO: tag:${versiondetail} set, updating from tag ${versiondetail} commit ${commit}"
    fi
    git checkout $commit --quiet
    if [ $? -ne 0 ]; then
      log "ERROR: unable to checkout commit $commit for tag $tag, might not exist yet or have any files"
      return 1
    fi
    ;;
  *)
    log "FATAL: unknown VERSION_MODE $VERSION_MODE. Must be one of commit,branch,tag or leave blank for branch:master"  >&2
    exit 1
    ;;
  esac

  set -e
}

preprocess() {
  local execcommand=$1
  local targetdir=$2
  local tmpoutdir=$3
  local ymldir=$4

  if [ -n "$execcommand" ]; then
    log "INFO: Running transformation $execcommand"
    actualcommand=$(echo "$execcommand" | INDIR=$targetdir OUTDIR=$tmpoutdir envsubst)
    INDIR=$targetdir OUTDIR=$tmpoutdir $actualcommand
    log "INFO: kubernetes yml dir set to outdir $tmpoutdir"
  elif [ -n "$ymldir" ]; then
    log "INFO: cmd empty, no transformation to run"
    log "INFO: kubernetes yml dir set to configured ymldir relative to repository root:  $ymldir"
    cp -r $targetdir/$ymldir/. $tmpoutdir
  else
    log "INFO: cmd empty, no transformation to run"
    log "INFO: kubernetes yml dir set to default of repository root"
    cp -r $targetdir/. $tmpoutdir
  fi
}

apply() {
  local ymldir=$1
  local privileged=$2
  local dryrun=$3

  set +e 
  if [ -n "$dryrun" ]; then
    log "INFO: DRYRUN set, would have run: "
    log "INFO: kubectl $KUBECTL_OPTIONS apply -f $ymldir"
  else
    log "INFO: applying kubectl to directory $ymldir"
    runcmd kubectl $KUBECTL_OPTIONS apply -f $ymldir
    if [ $? -ne 0 ]; then
      log "ERROR: unable to apply kubectl due to error, skipping..."
      return 1
    fi
  fi

  set -e
}

# base loop that performs the update and apply
run() {
  local configurl="$1"
  local gdir="$2"
  local outdir="$3"
  local username="$4"
  local password="$5"
  local versiontype="$6"
  local versiondetail="$7"

  # update RoleBindings for each namespace
  local namespaces=$(runcmd kubectl $KUBECTL_OPTIONS get namespace --field-selector=metadata.name!=kube-system -o custom-columns=name:metadata.name --no-headers )
  for n in $namespaces; do
    genrole $n | runcmd kubectl $KUBECTL_OPTIONS apply -f -
  done
  

  # refresh our repo list
  json=$(getconfig $configurl)

  # count how many repos we have?
  count=$(echo $json | jq '. | length')

  ####
  # 
  # check each repo in stage/ dir via its name and remote. If it isn't in config, get rid of it.
  # 
  ####
  allurls=$(echo $json | jq -r '.[].url')
  for dir in $gdir/*; do
    [ -d $dir ] || continue
    remoteurl=$(git -C $dir remote get-url origin || echo)
    if [ -z "$remoteurl" ]; then
      log "INFO: $dir has no remote named origin, deleting."
      rm -rf $dir
    elif ! echo $remoteurl | grep -q $allurls; then
      log "INFO: $dir has remote url $remoteurl which is not in our config, deleting."
      rm -rf $dir
    fi
  done 
 
  # go to each repo
  # loop through the repos
  j=0
  while [ $j -lt $count ]; do
    repo=$(echo $json | jq -r ".[$j].url")
    cmd=$(echo $json | jq -r ".[$j] | select(.cmd) | .cmd")
    ymldir=$(echo $json | jq -r ".[$j] | select(.ymldir) | .ymldir")
    privileged=$(echo $json | jq -r ".[$j] | select(.privileged) | .privileged")
    reponame=$(repotodir $repo)

    # we need a repo
    if [ -z "$repo" ]; then
      log "ERROR: Repository $j in config does not have a repo defined as property 'url'" >&2
      exit 1
    fi

    cd $gdir 

    # clean up old output directory
    tmpoutdir=$outdir/$reponame
    rm -rf $tmpoutdir
    mkdir -p $tmpoutdir

    # make sure we already have the repo cloned
    if [ ! -d $gdir/$reponame ]; then
      # were credentials provided? if so, save them
      # we do not need ot check if the password exists; empty passwords are fine
      if [ -n "$username" ]; then
        git config --global credential.${repo}.username ${username}
        echo "https://${username}:${password}@${repo##https://}" >> ~/.git-credentials
      fi

      getrepo $repo $gdir
    fi

    # do the rest from within the repo
    cd $gdir/$reponame

    update_repo
    checkout_version $versiontype $versiondetail || (j=$(( $j + 1 )) && continue)
    preprocess "$cmd" "$PWD" "$tmpoutdir" "$ymldir"
    validate_privileged "$privileged" "$tmpoutdir" || (log "ERROR: Unprivileged repo requires privilege ${reponame}" && j=$(( $j + 1 )) && continue)
    apply "$tmpoutdir" "$privileged" "$DRYRUN" || (j=$(( $j + 1 )) && continue)

    j=$(( $j + 1 ))
  done
  log "INFO: done"
}

# were credentials provided?
username=
password=
if [ -n "$REPOCREDS" ]; then
  # if there is no ":" then username=REPOCREDS and password=""
  case $REPOCREDS in
    *:*)
      username=${REPOCREDS%%:*}
      password=${REPOCREDS#*:}
      ;;
    *)
      username=${REPOCREDS}
      password=
      ;;
  esac
  git config --global credential.helper 'store --file ~/.git-credentials'
fi

# we download repos to per-repo subdirs of /git/src
# processed output goes to per-repo subdirs /git/out
gdir=$HOME/git/src
outdir=$HOME/git/out
sleepinterval=${INTERVAL:-300}

# clean up everything at beginning
rm -rf $gdir $outdir
mkdir -p $gdir $outdir

#####
#
# determine mode for branch
#
#####

# what mode are we in?
if [ -z "$VERSION_MODE" ]; then
  VERSION_MODE="branch:master"
fi
versiontype=${VERSION_MODE%%:*}
versiondetail=${VERSION_MODE##*:}

if [ -z "$versiontype" ]; then
  log "FATAL: must specify VERSION_MODE with one of commit,branch,tag or leave blank for branch:master"  >&2
  exit 1
fi


#####
#
# Process config file
#
#####
configurl=${CONFIG:-/kubesync.json}

#####
# 
# keep up to date
#
#####

# loop forever
while true; do
  run $configurl $gdir $outdir "$username" "$password" $versiontype $versiondetail

  if [ -n "$ONCE" ]; then
    log "INFO: ONCE=${ONCE} exiting."
    break
  fi

  log "INFO: awaiting next update in $sleepinterval seconds..."
  sleep $sleepinterval
done

