#!/bin/bash
#
# Copyright 2017 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e
set -o pipefail

# Import some functions from other scripts.
source $(dirname $0)/build_google_image_functions.sh


function show_usage() {
    fix_defaults

cat <<EOF
Usage:  $0 [options]

   --account ACCOUNT
       [$ACCOUNT]
       Use this gcloud account to build the image.

   --image_project IMAGE_PROJECT
      [$IMAGE_PROJECT]
      The project for the SOURCE_IMAGE or BASE_IMAGE. The default is the
      PROJECT.

   --install_script INSTALL_SCRIPT
       [$INSTALL_SCRIPT]
       The path or URL to the install script to use.

   --no_update_os
       Do not force an upgrade-dist of the base OS.

   --build_project BUILD_PROJECT
       [$BUILD_PROJECT]
       Build the images in the BUILD_PROJECT id.

   --publish_project PUBLISH_PROJECT
       [$PUBLISH_PROJECT]
       Publish the images in the PUBLISH_PROJECT id.

   --version VERSION
       [$VERSION]
       The exact Spinnaker version we are baking images for.

   --zone ZONE
       [$ZONE]
       Zone to use when building the image. The final image is global.

EOF
}


function process_args() {
  while [[ $# > 0 ]]; do
    local key="$1"
    shift

    case $key in
        --help)
            show_usage
            exit
            ;;
        --account)
            ACCOUNT=$1
            shift
            ;;
        --image_project)
            IMAGE_PROJECT=$1
            shift
            ;;
        --install_script)
            INSTALL_SCRIPT=$1
            shift
            ;;
        --no_update_os)
            UPDATE_OS=false
            ;;
        --build_project)
            BUILD_PROJECT=$1
            shift
            ;;
        --publish_project)
            PUBLISH_PROJECT=$1
            shift
            ;;
        --version)
            VERSION=$1
            shift
            ;;
        --zone)
            ZONE=$1
            shift
            ;;
        *)
          show_usage
          >&2 echo "Unrecognized argument '$key'."
          exit -1
    esac
  done
}


function create_component_prototype_disk() {
  local install_script_path
  local component=$1
  local version=$2

  install_script_path=$(basename $INSTALL_SCRIPT)

  echo "`date`: Creating prototype instance '$BUILD_INSTANCE'"
  gcloud compute instances create $BUILD_INSTANCE \
      --project $BUILD_PROJECT \
      --account $ACCOUNT \
      --zone $ZONE \
      --machine-type n1-standard-1 \
      --boot-disk-type pd-ssd \
      --image $BASE_IMAGE  \
      --image-project $IMAGE_PROJECT \
      --metadata-from-file ssh-keys=$HOME/.ssh/google_empty.pub \
      --metadata block-project-ssh-keys=TRUE,startup-script="apt-get install -y git; git clone https://github.com/spinnaker/spinnaker.git"

  trap cleanup_instances_on_error EXIT

  PROTOTYPE_INSTANCE=$BUILD_INSTANCE

  # This second instance will be used later to clean the image
  # we dont need it yet, but will spin it up now to have it ready.
  echo "`date` Warming up '$CLEANER_INSTANCE' for later"
  (gcloud compute instances create ${CLEANER_INSTANCE} \
      --project $BUILD_PROJECT \
      --account $ACCOUNT \
      --zone $ZONE \
      --machine-type n1-standard-1 \
      --image $BASE_IMAGE \
      --metadata-from-file ssh-keys=$HOME/.ssh/google_empty.pub \
      --metadata startup-script="apt-get install -y git; git clone https://github.com/spinnaker/spinnaker.git" \
      --image-project $IMAGE_PROJECT >& /dev/null&)

  args="--component $component --version $version"
  command="sudo bash /spinnaker/dev/$(basename $INSTALL_SCRIPT) ${args}"
  sleep 120 # Wait for the startup scripts to complete.

  echo "`date`: Installing $component and spinnaker-monitoring onto '$BUILD_INSTANCE'"
  sudo gcloud alpha compute ssh $BUILD_INSTANCE \
    --internal-ip \
    --project $BUILD_PROJECT \
    --account $ACCOUNT \
    --zone $ZONE \
    --ssh-key-file $SSH_KEY_FILE \
    --command="$command"

  if [[ "$UPDATE_OS" == "true" ]]; then
    echo "`date`: Updating distribution on '$BUILD_INSTANCE'"
    sudo gcloud alpha compute ssh $BUILD_INSTANCE \
      --internal-ip \
      --project $BUILD_PROJECT \
      --account $ACCOUNT \
      --zone $ZONE \
      --ssh-key-file $SSH_KEY_FILE \
      --command="sudo DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade && sudo apt-get autoremove -y"
  fi

  echo "`date`: Deleting '$BUILD_INSTANCE' but keeping disk"
  gcloud compute instances set-disk-auto-delete $BUILD_INSTANCE \
    --project $BUILD_PROJECT \
    --account $ACCOUNT \
    --zone $ZONE \
    --no-auto-delete \
    --disk $BUILD_INSTANCE

  # This will be on success too
  trap delete_prototype_disk EXIT

  # Just the builder instance, not the cleanup instance
  delete_build_instance
}


function create_component_image() {
  local artifact=$1
  local service=$2
  ARTIFACT_VERSION="$(hal version bom $VERSION --artifact-name ${artifact} --quiet --color false)"
  # Target image is named spinnaker-${artifact}-${artifact-version} with dashes replacing dots.
  TARGET_IMAGE="$(echo spinnaker-${artifact}-${ARTIFACT_VERSION} | sed 's/[\.:]/\-/g')"
  echo $TARGET_IMAGE
  CLEANER_INSTANCE="clean-${TARGET_IMAGE}"
  BUILD_INSTANCE="build-${TARGET_IMAGE}"

  create_component_prototype_disk $service $VERSION
  extract_clean_prototype_disk "$BUILD_INSTANCE" "$CLEANER_INSTANCE"
  image_from_prototype_disk "$TARGET_IMAGE" "$BUILD_INSTANCE"

  trap - EXIT

  delete_prototype_disk

  # Set $PROJECT to the publish project so we can clear the target
  # image and disk if it exists.
  PROJECT=$PUBLISH_PROJECT
  delete_disk_if_exists $TARGET_IMAGE
  delete_image_if_exists $TARGET_IMAGE
  bash spinnaker/google/dev/publish_gce_release.sh \
    --zone $ZONE \
    --service_account $ACCOUNT \
    --original_image $TARGET_IMAGE \
    --original_project $BUILD_PROJECT \
    --publish_image $TARGET_IMAGE \
    --publish_project $PUBLISH_PROJECT

  # Clear the image and disk from the build project after the copy.
  PROJECT=$BUILD_PROJECT
  delete_disk_if_exists $TARGET_IMAGE
  delete_image_if_exists $TARGET_IMAGE
}


function fix_defaults() {
  # No source image, so assume a base image (to install from).
  if [[ "$SOURCE_IMAGE" == "" ]]; then
    local image_entry=$(gcloud compute images list 2>&1 \
                        | grep $BASE_IMAGE_OR_FAMILY | head -1)

    BASE_IMAGE=$(echo "$image_entry" | sed "s/\([^ ]*\) .*/\1/")

    # If this was a family, convert it to a particular image for
    # argument consistency
    if [[ "$IMAGE_PROJECT" == "" ]]; then
      IMAGE_PROJECT=$(echo "$image_entry" | sed "s/[^ ]* *\([^ ]*\)* .*/\1/")
    fi
  fi
}


process_args "$@"

# map of artifact -> service
# artifact is an unconfigured installable package/binary
# service is a configured artifact
declare -A COMPONENTS=( ['clouddriver']='clouddriver' \
  ['deck']='deck' \
  ['echo']='echo' \
  ['fiat']='fiat' \
  ['front50']='front50' \
  ['gate']='gate' \
  ['igor']='igor' \
  ['orca']='orca' \
  ['rosco']='rosco' \
  ['consul']='consul-server' \
  ['vault']='vault-server' \
  ['redis']='redis')

TIME_DECORATOR=$(date +%Y%m%d%H%M%S)
ZONE=us-central1-f
BASE_IMAGE_OR_FAMILY=ubuntu-1404-lts
SSH_KEY_FILE=$HOME/.ssh/google_empty

fix_defaults
create_empty_ssh_key

for artifact in "${!COMPONENTS[@]}"; do
  service=${COMPONENTS[$artifact]}
  LOG="create-${service}-image.log"
  echo "Creating component image for $service with artifact $artifact; output will be logged to $LOG..."
  create_component_image $artifact $service &> $LOG &
done

# We track the subprocesses by job instead of pid since
# waiting for the pids requires the subprocesses still be running.
# If we are waiting for process i, and process i+1 finishes, `wait`
# will fail to find process i+1 and incorrectly fail and exit.
# Job IDs exist and can be waited on even after the actual subprocess exits.
FAILED=0
for job in $(jobs -p); do
  echo "Waiting for job $job"
  wait $job || let "FAILED+=1"
done

for logfile in *-image.log; do
  echo "---- start $logfile ----"
  echo ""
  cat $logfile
  echo ""
  echo "---- end $logfile ----"
done

if [ "$FAILED" == "0" ]; then
  echo "All jobs succeeded."
else
  echo "Some jobs failed. Exiting..."
  exit "$FAILED"
fi


echo "`date`: DONE"
