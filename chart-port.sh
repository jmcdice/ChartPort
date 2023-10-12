#!/bin/bash

set -eEuo pipefail  # Enable strict error handling

DRY_RUN=false

function exit_with_error() {
  echo "$1"
  exit 1
}

function dry_run_notify() {
  if $DRY_RUN; then
    echo "[DRY-RUN]: $1"
  fi
}

function add_helm_repo() {
  helm repo add $1 $2 || { echo "Failed to add Helm repo"; exit 1; }
  helm repo update || { echo "Failed to update Helm repo"; exit 1; }
}

function download_helm_chart_manifest() {
  local values_file_option=""
  if [[ -n $6 ]]; then
    values_file_option="-f $6"
  fi
  eval "helm template $1/$2 --version $3 $4 $values_file_option > $5" || exit_with_error "Failed to download Helm chart manifest"
}

function download_helm_chart() {
  helm pull $1 --version $2 --untar --untardir $3 || exit_with_error "Failed to download Helm chart"
}

function download_images() {
  local manifest_file=$1
  local root_dir=$2
  local chart_name=$3  # New argument for the chart name

  mkdir -p "$root_dir/$chart_name"  # Adjusted to include the chart name

  local image_list=$(awk -F'image: ' '/image: /{gsub("\"","",$2); print $2}' $manifest_file | sort -u) || { echo "Failed to extract image names"; exit 1; }

  # Adjusted to include the chart name in the path
  local images_file="$root_dir/$chart_name/images.txt"
  echo "Images:" > $images_file

  for image in $image_list; do
    IFS=':' read -r full_name tag <<< "$image"
    local repo_name=$(echo $full_name | tr '/' '_')  # Changed variable name for clarity

    mkdir -p "$root_dir/$chart_name/$repo_name/$tag"  # Adjusted to include the chart name

    local sanitized_image=$(echo $image | sed 's/@[^ ]*//g')
    local sanitized_name=$(echo $repo_name-$tag | sed 's/@[^ ]*//g')
    local image_file="$root_dir/$chart_name/$repo_name/$tag/$sanitized_name.tar"

    if [[ -e $image_file ]]; then
      echo "Image file $image_file already exists, skipping..."
    else 
      docker pull $sanitized_image || { echo "Failed to pull image $sanitized_image"; exit 1; }
      docker save $sanitized_image -o $image_file || { echo "Failed to save image $sanitized_image"; exit 1; }
    fi

    # Append the image name to the images.txt file
    echo "$full_name:$tag" | sed 's/@[^ ]*//g' >> $images_file
  done
}

function download() {
  local chart_repo_url=${1%/}
  local chart_name=$2
  local chart_version=$3
  local values_file=$4  # Adding a new argument for the optional values file
  shift 4  # Adjusting the shift to account for the new argument
  local additional_helm_flags="$@"
  local repo_name=$(echo ${chart_repo_url##*/} | tr -d '/')
  local actual_chart_name=${chart_name##*/}

  local root_dir="cache-root/images"
  local helm_charts_dir="cache-root/helm-charts"
  local manifest_file="$helm_charts_dir/${actual_chart_name}-manifests.yaml"

  mkdir -p $helm_charts_dir  # Create a directory for the Helm chart

  add_helm_repo $repo_name $chart_repo_url
  download_helm_chart_manifest $repo_name $actual_chart_name $chart_version "$additional_helm_flags" $manifest_file $values_file
  download_helm_chart $repo_name/$actual_chart_name $chart_version $helm_charts_dir
  download_images $manifest_file $root_dir $actual_chart_name

  # Metadata file creation
  local metadata_file="$helm_charts_dir/$actual_chart_name/metadata.txt"
  echo "Chart Repo URL: $chart_repo_url" > $metadata_file
  echo "Chart Name: $chart_name" >> $metadata_file
  echo "Chart Version: $chart_version" >> $metadata_file
  echo "Download Date: $(date)" >> $metadata_file

  #rm $manifest_file

  echo "Images saved in $root_dir"
  echo "Helm chart saved in $helm_charts_dir"
}

function tag_and_push_images() {
  local chart_name=$1
  local new_registry_url=$2
  local root_dir="cache-root/images/$chart_name"

  for dir in $(ls $root_dir); do
    local original_repo=$(echo $dir | tr '_' '/')
    for sub_dir in $(ls $root_dir/$dir); do
      # Skip if not a directory
      if [[ ! -d "$root_dir/$dir/$sub_dir" ]]; then
        continue
      fi

      local image_tar_path=$(find "$root_dir/$dir/$sub_dir" -name "*.tar" -type f)
      if [[ -z $image_tar_path ]]; then
        echo "No image tar found in $root_dir/$dir/$sub_dir"
        continue
      fi


      local tag=$sub_dir
      # If tag contains '@', split and reformat it
      if [[ $tag == *@* ]]; then
        local semantic_tag=$(echo $tag | cut -d '@' -f 1)
        local sha=$(echo $tag | cut -d '@' -f 2)

        tag="${semantic_tag}_$(echo $sha | tr -d '[:punct:]')"
      fi

      # Adjusted new_ref to include the chart name as a separate repository
      local new_ref="$new_registry_url/$chart_name/$original_repo:$tag"
      
      if $DRY_RUN; then
        echo "Would tag $original_repo:$tag and push as $new_ref"
        echo "Docker Load: $image_tar_path"
      else
        docker load < $image_tar_path || { echo "Failed to docker load image: $image_tar_path"; exit 1; }
        docker tag $original_repo:$tag $new_ref || { echo "Failed to tag $original_repo:$tag to $new_ref"; exit 1; }
        docker push $new_ref || { echo "Failed to push $new_ref"; exit 1; }
      fi
    done
  done
}

function update_image_references() {
  local full_old_ref=$1
  local new_ref=$2
  local helm_chart_dir=$3

  # Extract just the repository portion from the full reference
  local old_ref=${full_old_ref%%:*}

  # Find all values.yaml files in the Helm chart directory
  find "$helm_chart_dir" -name values.yaml | while read -r values_file; do
    echo "Looking at: $values_file"
    
    # Check if the repository reference exists in the current file
    if grep -qE "repository:[[:space:]]+$old_ref" "$values_file"; then
      if $DRY_RUN; then
        echo "Would replace $old_ref with $new_ref in $values_file"
      else
        # Create a backup of the current file
        cp "$values_file" "$values_file.bak"
        
        # Perform the replacement in the current file
        sed -i -E "s|(repository:[[:space:]]+)$old_ref|\1$new_ref|g" "$values_file"
      fi
    fi
  done
}

function update_all_image_references() {

  local chart_name=$1
  local new_registry_url=$2
  local helm_chart_dir="cache-root/helm-charts/$chart_name"

  local root_dir="cache-root/images/$chart_name"

  for dir in $(ls $root_dir); do
    if [[ $dir == "images.txt" ]]; then
      continue
    fi
    local original_repo=$(echo $dir | tr '_' '/')
    for sub_dir in $(ls $root_dir/$dir); do

      local tag=$sub_dir
      # Adjusted new_ref to include the chart name as a separate repository
      local new_ref="$new_registry_url/$chart_name/$original_repo:$tag"
      update_image_references $original_repo:$tag $new_ref $helm_chart_dir
    done
  done
}

function upload() {
  local chart_name=$1
  local new_registry_url=$2

  tag_and_push_images $chart_name $new_registry_url
  update_all_image_references $chart_name $new_registry_url
}

function list_charts() {
  local helm_charts_dir="cache-root/helm-charts"
  
  if [ ! "$(ls -A $helm_charts_dir)" ]; then
    echo "No charts found locally."
    return
  fi
  
  echo "Local charts:"
  for chart_dir in $(ls $helm_charts_dir); do
    if [ -d "$helm_charts_dir/$chart_dir" ]; then
      local metadata_file="$helm_charts_dir/$chart_dir/metadata.txt"
      if [ ! -f $metadata_file ]; then
        echo "  - $chart_dir (Metadata not found)"
        echo 
      else
        echo "  - $chart_dir"
        cat $metadata_file | sed 's/^/    /'  # Indent metadata contents
        echo 
      fi
    fi
  done
}

function usage() {
  echo "Usage: $0 [ --dry-run ] <command> [arguments]"
  echo "Commands:"
  echo "  download <chart_repo_url> <chart_name> <chart_version> [additional_helm_flags]"
  echo "  upload <chart> <new_registry_url>"
  echo "  list (list local charts)"
  echo ""
}

trap 'exit_with_error "Error at line $LINENO"' ERR

function main() {
  if [[ $# -ge 1 && $1 == "--dry-run" ]]; then
    DRY_RUN=true
    shift  # Remove --dry-run from arguments
  fi
  
  if [[ $# -lt 1 ]]; then
    echo "No command provided"
    usage
    exit 1
  fi

  local command=$1
  shift

  case $command in
    list)
      list_charts
      ;;
    download)
      download "$@"
      ;;
    upload)
      if [[ $# -ne 2 ]]; then
        usage
        exit 1
      fi
      upload "$1" "$2"
      ;;
    *)
      echo "Unknown command: $command"
      usage
      exit 1
      ;;
  esac
}

main "$@"
