# Helm Chart and Image Caching Utility

This utility script is created to facilitate the caching of Helm charts and associated Docker images to a local registry. The script consists of various functions each serving a specific purpose in the process of downloading, caching, and uploading the Helm charts and Docker images.

## Getting Started

These instructions will get you a copy of the script up and running on your local machine for development and testing purposes.

### Prerequisites

- Bash environment
- Docker installed and running
- Helm installed

### Installation

1. Clone the repository to your local machine.
2. Navigate to the directory containing the script.
3. Ensure the script is executable by running `chmod +x chart-port.sh`.

## Usage

The script supports three primary commands: `download`, `upload`, and `list`.

### Downloading Helm Charts and Images

To download a Helm chart and its associated images, use the `download` command followed by the chart repository URL, chart name, and chart version.

```console
  ./chart-port.sh download <chart_repo_url> <chart_name> <chart_version> [additional_helm_flags]
```

The `additional_helm_flags` argument is optional and can be used to pass additional flags to the `helm` command.

### Uploading Images to a New Registry

To upload the cached images to a new registry, use the `upload` command followed by the chart name and the new registry URL.

```console
  ./chart-port.sh upload <chart_name> <new_registry_url>
```

### Listing Cached Charts

To list the charts that have been cached locally, use the `list` command.

```console 
  ./chart-port.sh list
```

## Dry Run Mode

The script supports a dry run mode which can be enabled by passing the `--dry-run` flag before the command. In dry run mode, the script will output the actions it would perform without actually executing them.

```console
  ./chart-port.sh --dry-run <command> [arguments]
```

## Error Handling

The script has built-in error handling which will halt the script execution and output an error message upon encountering an error.


