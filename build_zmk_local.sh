#!/usr/bin/env bash
#
# ZMK Firmware Local Build Script
#
# This script automates building ZMK keyboard firmware locally using containerized
# build environments (Podman/Docker). It dynamically reads build configurations from
# build.yaml and manages west dependencies from config/west.yml.
#
# Features:
#   - Automatic initialization and dependency management
#   - Dynamic configuration from YAML files (no hardcoded targets)
#   - Build all firmware or specific targets
#   - Incremental builds for faster development
#   - Clean management (build artifacts or full dependencies)
#   - Auto-generated .gitignore from west.yml
#   - Build artifact copying with timestamping
#
# Quick Start:
#   ./build_local.sh build          # Initialize (if needed) and build all firmware
#   ./build_local.sh help           # Show detailed usage
#
# Author: Generated for zmk-sofle project
# License: Same as ZMK (MIT)
#

set -euo pipefail

# Configuration
RUNTIME="${RUNTIME:-docker}" # Could be docker or podman
IMG="${ZMK_IMAGE:-docker.io/zmkfirmware/zmk-build-arm:4.1-branch}"
ENV="-e CMAKE_PREFIX_PATH=/zmk/zephyr:${CMAKE_PREFIX_PATH:-}"

echo $RUNTIME

# Base command components
RUNTIME_RUN="$RUNTIME run --rm"
VOLUME_MOUNTS="-v $(pwd):/zmk -v /tmp:/temp"
WORKDIR="--workdir /zmk"
ENV_ARGS="$ENV"
IMAGE="$IMG"
COMMAND="$RUNTIME_RUN $VOLUME_MOUNTS $WORKDIR $ENV_ARGS $IMAGE" # Base command without user mapping
BUILD_CONFIG="${BUILD_CONFIG:-build.yaml}"
INCREMENTAL="${INCREMENTAL:-false}" # Set to true to skip -p (pristine) flag for faster incremental builds

log_info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}
log_error() {
  echo -e "\033[0;31m[ERROR]\033[0m $1" >&2
}
log_warning() {
  echo -e "\033[1;33m[WARNING]\033[0m $1" >&2
}
log_success() {
  echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

check_directory_permissions() {
  local dir="$1"
  local operation="$2"

  if [ ! -w "$dir" ]; then
    log_error "Permission denied: Cannot $operation in $dir"
    echo ""
    echo "Possible solutions:"
    echo "  1. Change ownership: sudo chown -R \$USER:$USER $dir"
    echo "  2. Adjust permissions: chmod u+w $dir"
    echo "  3. Run with proper user context"
    echo ""
    echo "If using Podman with rootless containers, ensure:"
    echo "  - User namespaces are configured: /etc/subuid and /etc/subgid"
    echo "  - Or run with: podman unshare $0 [command]"
    exit 1
  fi
}

validate_build_environment() {
  log_info "Validating build environment permissions..."

  # Check current directory write permissions
  check_directory_permissions "$(pwd)" "write files"

  # Check if build directory can be created/written
  if [ -d "./build" ] && [ ! -w "./build" ]; then
    check_directory_permissions "./build" "write build artifacts"
  fi

  # Check west-managed directories for write access if they exist
  local critical_dirs=("zephyr" "zmk" "modules" "tools")
  for dir in "${critical_dirs[@]}"; do
    if [ -d "./$dir" ] && [ ! -w "./$dir" ]; then
      log_error "Permission denied: Cannot write to ./$dir directory"
      echo ""
      echo "This directory is required for ZMK builds. To fix:"
      echo "  sudo chown -R \$USER:$USER $dir"
      echo "  chmod -R u+w $dir"
      exit 1
    fi
  done

  # Check temporary directory access
  if [ ! -w "/tmp" ]; then
    log_error "Cannot write to /tmp directory"
    echo "This is required for container volume mounting"
    exit 1
  fi
}

# Get the name of the keyboard from the parent directory if possible
THIS_SCRIPT=$(readlink -f $0)
SCRIPT_DIR=$(dirname $THIS_SCRIPT)
SCRIPT_DIR_NAME=$(basename $SCRIPT_DIR)
case $SCRIPT_DIR_NAME in
zmk-sofle) KEYBOARD="eyelash_sofle" ;; # For backwards compatibility
zmk-config-*) KEYBOARD=${SCRIPT_DIR_NAME#zmk-config-} ;;
zmk-*) KEYBOARD=${SCRIPT_DIR_NAME#zmk-} ;;
totem-*) KEYBOARD="totem" ;;
*)
  if [ -z "${KEYBOARD:+set}" ]; then
    log_error "KEYBOARD not set and cannot be found from directory name: $SCRIPT_DIR_NAME"
    exit 1
  fi
  ;;
esac

# Parse YAML file and extract build configurations
# Returns: board|shield|snippet|cmake-args|artifact-name for each build
parse_build_config() {
  if [ ! -f "$BUILD_CONFIG" ]; then
    log_error "Build configuration file not found: $BUILD_CONFIG"
    exit 1
  fi

  # Simple YAML parser that extracts build configurations
  # This avoids external dependencies like yq
  local in_include=0
  local board="" shield="" snippet="" cmake_args="" artifact_name=""
  local config_count=0

  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Check if we're in the include section
    if [[ "$line" =~ ^include: ]]; then
      in_include=1
      continue
    fi

    if [ $in_include -eq 1 ]; then
      # New item starts with "- board:"
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+board:[[:space:]]*(.+) ]]; then
        # Output previous config if exists
        if [ -n "$board" ]; then
          # Auto-generate artifact name if missing
          if [ -z "$artifact_name" ]; then
            config_count=$((config_count + 1))
            artifact_name="build_${config_count}"
            log_warning "Auto-generated artifact name '$artifact_name' for board: $board"
          fi
          echo "${board}|${shield}|${snippet}|${cmake_args}|${artifact_name}"
        fi

        # Start new config
        board="${BASH_REMATCH[1]}"
        shield=""
        snippet=""
        cmake_args=""
        artifact_name=""
      elif [[ "$line" =~ ^[[:space:]]+shield:[[:space:]]*(.+) ]]; then
        shield="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+snippet:[[:space:]]*(.+) ]]; then
        snippet="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+cmake-args:[[:space:]]*(.+) ]]; then
        cmake_args="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+artifact-name:[[:space:]]*(.+) ]]; then
        artifact_name="${BASH_REMATCH[1]}"
      fi
    fi
  done <"$BUILD_CONFIG"

  # Output last config with auto-generated name if needed
  if [ -n "$board" ]; then
    if [ -z "$artifact_name" ]; then
      config_count=$((config_count + 1))
      artifact_name="build_${config_count}"
      log_warning "Auto-generated artifact name '$artifact_name' for board: $board"
    fi
    echo "${board}|${shield}|${snippet}|${cmake_args}|${artifact_name}"
  fi
}

# Parse west.yml and extract project names (these become directories)
parse_west_projects() {
  local west_file="${1:-config/west.yml}"

  if [ ! -f "$west_file" ]; then
    log_error "West manifest file not found: $west_file"
    exit 1
  fi

  local in_projects=0

  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Check if we're in the projects section
    if [[ "$line" =~ ^[[:space:]]*projects: ]]; then
      in_projects=1
      continue
    fi

    # Exit projects section when we hit another top-level key
    if [ $in_projects -eq 1 ] && [[ "$line" =~ ^[[:space:]]*[a-z]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ^[[:space:]]*- ]]; then
      break
    fi

    if [ $in_projects -eq 1 ]; then
      # Extract project name
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+name:[[:space:]]*(.+) ]]; then
        echo "${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+name:[[:space:]]*(.+) ]]; then
        echo "${BASH_REMATCH[1]}"
      fi
    fi
  done <"$west_file"
}

# Check if Docker image is available locally, pull if needed
check_image() {
  if ! $RUNTIME image inspect "$IMG" &>/dev/null; then
    log_warning "Image $IMG not found locally. Pulling..."
    $RUNTIME pull "$IMG"
    log_success "Image pulled successfully"
  fi
}

# Build a specific firmware target from YAML config
build_target() {
  local target_name="$1"

  validate_build_environment
  check_init
  check_image

  local start_time
  start_time=$(date +%s)

  local found=0
  while IFS='|' read -r board shield snippet cmake_args artifact_name; do
    if [ "$artifact_name" = "$target_name" ]; then
      found=1
      log_info "Building ${artifact_name} firmware..."

      # Build the command arguments
      local build_args=()
      build_args+=("-d" "./build/${artifact_name}")

      # Add pristine flag unless incremental build is enabled
      if [ "$INCREMENTAL" != "true" ]; then
        build_args+=("-p")
      fi

      build_args+=("-b" "$board")
      build_args+=("-s" "/zmk/zmk/app")

      # Add snippet if specified
      if [ -n "$snippet" ]; then
        build_args+=("-S" "$snippet")
      fi

      # Add shield and cmake-args to cmake arguments
      local cmake_args_array=()
      cmake_args_array+=("-DZMK_CONFIG=/zmk/config")
      if [ -n "$shield" ]; then
        cmake_args_array+=("-DSHIELD=$shield")
      fi
      if [ -n "$cmake_args" ]; then
        read -ra extra_args <<<"$cmake_args"
        cmake_args_array+=("${extra_args[@]}")
      fi

      # Build command with user mapping
      local run_command=""
      if [ "$RUNTIME" = "podman" ]; then
        run_command="$RUNTIME_RUN --userns=keep-id $VOLUME_MOUNTS $WORKDIR $ENV_ARGS $IMAGE"
      elif [ "$RUNTIME" = "docker" ]; then
        run_command="$RUNTIME_RUN --user $(id -u):$(id -g) $VOLUME_MOUNTS $WORKDIR $ENV_ARGS $IMAGE"
      else
        run_command="$COMMAND"
      fi

      # Execute build with enhanced error handling
      if ! $run_command west build "${build_args[@]}" -- "${cmake_args_array[@]}"; then
        log_error "Build failed for $artifact_name"
        echo ""
        echo "Common build failure causes:"
        echo "  1. Insufficient disk space"
        echo "  2. Network connectivity issues"
        echo "  3. Missing dependencies in container"
        echo "  4. Incorrect board/shield configuration"
        echo ""
        echo "Try running with INCREMENTAL=false for a clean build"
        echo "Or try: RUNTIME=docker $0 build $target_name"
        return 1
      fi

      if ! check_build_artifact "./build/${artifact_name}/zephyr/zmk.uf2" "${artifact_name} build"; then
        log_error "Build artifacts not found for $artifact_name"
        echo "This indicates the build process failed silently"
        echo "Check the build output above for specific error messages"
        return 1
      fi

      # Rename artifact to match target name
      cp "./build/${artifact_name}/zephyr/zmk.uf2" "./build/${artifact_name}.uf2"
      log_success "Artifact saved to: ./build/${artifact_name}.uf2"

      local end_time
      end_time=$(date +%s)
      local duration=$((end_time - start_time))
      log_success "Build completed in ${duration}s"
      break
    fi
  done < <(parse_build_config)

  if [ $found -eq 0 ]; then
    log_error "Target '$target_name' not found in $BUILD_CONFIG"
    echo ""
    echo "Available targets:"
    list_targets | head -20
    return 1
  fi
}

# Check if the container runtime is available
check_container_runtime() {
  if ! command -v "$RUNTIME" &>/dev/null; then
    log_error "Error: $RUNTIME could not be found."
    echo ""
    case "$RUNTIME" in
    podman*)
      echo "To install Podman:"
      echo "  Ubuntu/Debian: sudo apt install podman"
      echo "  Fedora: sudo dnf install podman"
      echo "  macOS: brew install podman"
      echo "  Windows: Download from https://podman.io/"
      ;;
    docker*)
      echo "To install Docker:"
      echo "  Ubuntu/Debian: sudo apt install docker.io"
      echo "  Fedora: sudo dnf install docker"
      echo "  macOS: Download Docker Desktop"
      echo "  Windows: Download Docker Desktop"
      ;;
    esac
    echo ""
    echo "Alternatively, run with: RUNTIME=docker $0 [command]"
    exit 1
  fi

  # Check Podman-specific requirements
  if [[ "$RUNTIME" == podman* ]]; then
    check_podman_requirements
  fi
}

check_podman_requirements() {
  # Check if user namespaces are configured
  local username=$(whoami)
  if ! grep -q "^$username:" /etc/subuid 2>/dev/null; then
    log_error "User namespaces not configured for $username"
    echo ""
    echo "For Podman to work correctly, configure user namespaces:"
    echo "  echo '$username:524288:65536' | sudo tee -a /etc/subuid"
    echo "  echo '$username:524288:65536' | sudo tee -a /etc/subgid"
    echo ""
    echo "Then run: RUNTIME=docker $0 [command]"
    exit 1
  fi

  # Check if SELinux is enabled and .west directory has wrong context
  if command -v getenforce &>/dev/null; then
    local selinux_mode=$(getenforce 2>/dev/null || echo "Unknown")
    if [[ "$selinux_mode" == "Enforcing" ]] && [ -d "./.west" ]; then
      local current_context=$(/usr/bin/ls -Zd . 2>/dev/null | awk '{print $1}' | cut -d: -f3)

      if [[ "$current_context" != "container_file_t" ]]; then
        log_warning "SELinux context issue detected with project directory"
        echo ""
        echo "Podman requires correct SELinux contexts for user namespace mapping:"
        echo "  sudo chcon -Rt container_file_t ./"
        echo ""
        echo "Or run with Docker for easier setup:"
        echo "  RUNTIME=docker $0 [command]"
        echo ""
        echo "Or temporarily disable SELinux (not recommended):"
        echo "  sudo setenforce 0"
        echo ""
      fi
    fi
  fi
}

# Initialize the repo
init() {
  log_info "Initializing repository..."

  # Build command with user mapping
  local run_command=""
  if [ "$RUNTIME" = "podman" ]; then
    run_command="$RUNTIME_RUN --userns=keep-id $VOLUME_MOUNTS $WORKDIR $ENV_ARGS $IMAGE"
  elif [ "$RUNTIME" = "docker" ]; then
    run_command="$RUNTIME_RUN --user $(id -u):$(id -g) $VOLUME_MOUNTS $WORKDIR $ENV_ARGS $IMAGE"
  else
    run_command="$COMMAND"
  fi

  if ! $run_command west init -l config; then
    log_error "Failed to initialize west workspace"
    echo "This might be due to permission issues or missing user mapping"
    echo "Try running with: RUNTIME=docker $0 init"
    exit 1
  fi

  if ! $run_command west update; then
    log_error "Failed to update west dependencies"
    echo "Check network connectivity and disk space"
    exit 1
  fi

  log_success "Initialization complete"
}

# Update the repo
update() {
  log_info "Updating repository..."

  # Build command with user mapping
  local run_command=""
  if [ "$RUNTIME" = "podman" ]; then
    run_command="$RUNTIME_RUN --userns=keep-id $VOLUME_MOUNTS $WORKDIR $ENV_ARGS $IMAGE"
  elif [ "$RUNTIME" = "docker" ]; then
    run_command="$RUNTIME_RUN --user $(id -u):$(id -g) $VOLUME_MOUNTS $WORKDIR $ENV_ARGS $IMAGE"
  else
    run_command="$COMMAND"
  fi

  if ! $run_command west update; then
    log_error "Failed to update west dependencies"
    echo "Check network connectivity and disk space"
    exit 1
  fi

  log_success "Update complete."
}

check_init() {
  local needs_init=0

  # Check if .west directory exists (indicates west init has been run)
  if [ ! -d "./.west" ]; then
    log_warning "West workspace not initialized (.west/ not found)"
    needs_init=1
  fi

  # Check if zephyr directory exists
  if [ ! -d "./zephyr" ]; then
    log_warning "Zephyr SDK not found (zephyr/ not found)"
    needs_init=1
  fi

  # Check if main zmk project exists
  if [ ! -d "./zmk" ]; then
    log_warning "ZMK firmware not found (zmk/ not found)"
    needs_init=1
  fi

  # If any critical directory is missing, initialize
  if [ $needs_init -eq 1 ]; then
    log_warning "Repository not initialized. Running initialization..."
    init
    return 0
  fi

  # Check if all west projects from config/west.yml are present
  local missing_projects=()
  while IFS= read -r project_name; do
    if [ ! -d "./${project_name}" ]; then
      missing_projects+=("$project_name")
    fi
  done < <(parse_west_projects)

  # If any projects are missing, run update
  if [ ${#missing_projects[@]} -gt 0 ]; then
    log_warning "Missing west projects: ${missing_projects[*]}"
    log_info "Running west update to fetch missing projects..."
    update
  fi
}

# Verify build artifact exists
check_build_artifact() {
  local artifact_path="$1"
  local build_name="$2"

  if [ -f "$artifact_path" ]; then
    log_info "✓ $build_name successful: $artifact_path"
    return 0
  else
    log_error "✗ $build_name failed: Artifact not found at $artifact_path"
    return 1
  fi
}

# Build the firmware
build_dongle() {
  build_target "${KEYBOARD}_central_dongle_oled"
}

build_left() {
  build_target "${KEYBOARD}_peripheral_left"
}

build_central_left() {
  build_target "${KEYBOARD}_central_left"
}

build_right() {
  build_target "${KEYBOARD}_peripheral_right"
}

build_reset() {
  build_target "settings_reset"
}

build() {
  local failed=0
  local start_time
  start_time=$(date +%s)

  # Build all targets from YAML config
  while IFS='|' read -r board shield snippet cmake_args artifact_name; do
    build_target "$artifact_name" || failed=$((failed + 1))
  done < <(parse_build_config)

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  echo ""
  if [ $failed -eq 0 ]; then
    log_info "========================================"
    log_success "All builds completed successfully in ${duration}s!"
    log_info "========================================"
  else
    log_error "========================================"
    log_error "Build completed with $failed failure(s) in ${duration}s"
    log_error "========================================"
    exit 1
  fi
}

# List all available build targets from YAML
list_targets() {
  log_info "Available build targets from $BUILD_CONFIG:"
  echo ""
  # Suppress warnings during listing by redirecting stderr
  while IFS='|' read -r board shield snippet cmake_args artifact_name; do
    echo "  - $artifact_name"
    echo "      board: $board"
    [ -n "$shield" ] && echo "      shield: $shield"
    [ -n "$snippet" ] && echo "      snippet: $snippet"
    [ -n "$cmake_args" ] && echo "      cmake-args: $cmake_args"
    echo ""
  done < <(parse_build_config 2>/dev/null)
}

# Clean build artifacts
clean() {
  local target="${1:-}"

  if [ -n "$target" ]; then
    # Clean specific target
    if [ -d "./build/${target}" ]; then
      log_info "Cleaning build directory for ${target}..."
      rm -rf "./build/${target}"
      [ -f "./build/${target}.uf2" ] && rm "./build/${target}.uf2"
      log_success "Cleaned ./build/${target}"
    else
      log_warning "Build directory ./build/${target} does not exist"
    fi
  else
    # Clean all
    if [ -d "./build" ]; then
      log_info "Cleaning all build directories..."
      rm -rf ./build
      log_success "Cleaned ./build directory"
    else
      log_warning "Build directory does not exist"
    fi
  fi
}

# Clean all west-managed dependencies and build artifacts
clean_all() {
  log_warning "This will remove all west-managed dependencies and build artifacts"
  read -p "Are you sure? (y/N) " -n 1 -r
  echo

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Clean cancelled"
    return 0
  fi

  log_info "Cleaning build directory..."
  [ -d "./build" ] && rm -rf ./build

  log_info "Cleaning west-managed projects from config/west.yml..."
  while IFS= read -r project_name; do
    if [ -d "./${project_name}" ]; then
      log_info "Removing ${project_name}/"
      rm -rf "./${project_name}"
    fi
  done < <(parse_west_projects)

  # Also clean common west directories
  [ -d "./modules" ] && rm -rf ./modules && log_info "Removed modules/"
  [ -d "./tools" ] && rm -rf ./tools && log_info "Removed tools/"
  [ -d "./zephyr" ] && rm -rf ./zephyr && log_info "Removed zephyr/"
  [ -d "./optional" ] && rm -rf ./optional && log_info "Removed optional/"
  [ -d "./.west" ] && rm -rf ./.west && log_info "Removed .west/"

  log_success "All dependencies and build artifacts cleaned"
  log_info "Run './build_local.sh init' to reinitialize"
}

# Generate/update .gitignore based on west.yml
update_gitignore() {
  log_info "Generating .gitignore from config/west.yml..."

  local gitignore_file=".gitignore"
  local temp_file="${gitignore_file}.tmp"

  # Start with basic ignores
  cat >"$temp_file" <<'EOF'
# Build artifacts
build/
artifacts/

# ZMK
zephyr/
!zephyr/module.yml

# West managed directories
.west/
modules/
tools/
optional/

# West projects from config/west.yml
EOF

  # Add project directories from west.yml
  while IFS= read -r project_name; do
    echo "${project_name}/" >>"$temp_file"
  done < <(parse_west_projects)

  # Move temp file to actual gitignore
  mv "$temp_file" "$gitignore_file"
  log_success "Updated .gitignore with $(wc -l <"$gitignore_file") entries"
}

# Copy build artifacts to a defined directory
copy_artifacts() {
  DEST="${1:-./artifacts}"
  mkdir -p "$DEST"
  local copied=0

  # Copy all artifacts from YAML config
  while IFS='|' read -r board shield snippet cmake_args artifact_name; do
    local src_file="./build/${artifact_name}/zephyr/zmk.uf2"
    local dst_file="$DEST/${artifact_name}.uf2"

    if [ -f "$src_file" ]; then
      cp "$src_file" "$dst_file"
      log_info "Copied $artifact_name to $dst_file"
      copied=$((copied + 1))
    else
      log_warning "Artifact not found: $src_file (skipping)"
    fi
  done < <(parse_build_config)

  if [ $copied -gt 0 ]; then
    log_success "$copied artifact(s) copied to $DEST directory."
  else
    log_warning "No artifacts found to copy"
  fi
}

show_help() {
  cat <<EOF
ZMK Firmware Local Build Script Using Containerized Environment

The script allows you to build ZMK firmware targets defined in a YAML configuration file without the need to install all build dependencies locally. It uses a container runtime (Podman or Docker) to run the build environment.

Usage: $0 [flags] <command>

Commands:
  init             Initialize the repository (west init + update)
  update           Update the repository (west update)
  list             List all available build targets from build.yaml
  build_dongle     Build central dongle firmware
  build_left       Build peripheral left firmware
  build_right      Build peripheral right firmware
  build_central_left Build central left (no dongle) firmware
  build_reset      Build settings reset firmware
  build [name]     Build all firmware or specific target by name
  clean [target]   Clean build directory (all or specific target)
  clean_all        Clean all west dependencies and build artifacts
  gitignore        Generate/update .gitignore from config/west.yml
  copy [dest]      Copy build artifacts to directory (default: ./artifacts)
  help             Show this help message

Environment Variables:
  KEYBOARD        Name of the keyboard being built (default: extracted from directory name)
  RUNTIME       Container runtime (default: podman, can be docker)
  ZMK_IMAGE     ZMK build image (default: docker.io/zmkfirmware/zmk-build-arm:4.1-branch)
  BUILD_CONFIG  Build configuration file (default: build.yaml)
  INCREMENTAL   Skip pristine builds for faster rebuilds (default: false)

Examples:
  $0 build                                      # Build all firmware from build.yaml
  $0 build ${KEYBOARD}_peripheral_left          # Build specific target
  $0 list                                       # List all available targets
  $0 build_dongle                               # Build central dongle
  $0 build_left                                 # Build peripheral left
  $0 build_central_left                         # Build central left (no dongle)
  $0 clean                                      # Clean build artifacts
  $0 clean ${KEYBOARD}_peripheral_left          # Clean specific target
  $0 clean_all                       # Clean all west dependencies
  $0 gitignore                       # Update .gitignore from west.yml
  $0 copy                            # Copy artifacts to ./artifacts
  $0 copy /path/to/dir               # Copy artifacts to custom directory
  KEYBOARD=name $0 build             # Set the keyboard name manually
  INCREMENTAL=true $0 build_left     # Faster incremental build
  BUILD_CONFIG=custom.yaml $0 build  # Use custom build config
  RUNTIME=docker $0 build            # Use docker instead of podman

EOF
}

# Check if an argument was provided
if [ $# -eq 0 ]; then
  log_error "Error: No command provided"
  echo ""
  show_help
  exit 1
fi

# Parse flags
INCREMENTAL_FLAG=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
  -i | --incremental)
    INCREMENTAL_FLAG="true"
    shift
    ;;
  *)
    ARGS+=("$1")
    shift
    ;;
  esac
done

# Set incremental mode if flag was provided
if [ -n "$INCREMENTAL_FLAG" ]; then
  INCREMENTAL="true"
fi

# Restore positional parameters
set -- "${ARGS[@]}"

# Validate container runtime before processing commands
check_container_runtime

case "$1" in
init)
  init
  ;;
update)
  update
  ;;
list)
  list_targets
  ;;
build_dongle)
  build_dongle
  ;;
build_left)
  build_left
  ;;
build_right)
  build_right
  ;;
build_central_left)
  build_central_left
  ;;
build_reset)
  build_reset
  ;;
build)
  # If second argument provided, build specific target
  if [ -n "${2:-}" ]; then
    build_target "$2"
  else
    build
  fi
  ;;
clean)
  clean "${2:-}"
  ;;
clean_all)
  clean_all
  ;;
gitignore)
  update_gitignore
  ;;
copy)
  copy_artifacts "${2:-}"
  ;;
help | --help | -h)
  show_help
  ;;
*)
  log_error "Error: Unknown command '$1'"
  echo ""
  show_help
  exit 1
  ;;
esac
