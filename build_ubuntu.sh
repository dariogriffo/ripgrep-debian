ripgrep_VERSION=$1
BUILD_VERSION=$2
ARCH=${3:-amd64}  # Default to amd64 if no architecture specified

if [ -z "$ripgrep_VERSION" ] || [ -z "$BUILD_VERSION" ]; then
    echo "Usage: $0 <ripgrep_version> <build_version> [architecture]"
    echo "Example: $0 15.2.0 1 arm64"
    echo "Example: $0 15.2.0 1 all    # Build for all architectures"
    echo "Supported architectures: amd64, arm64, armhf, all"
    exit 1
fi

BUILD_DATE="$(date -R)"

# Function to map Ubuntu architecture to the ripgrep release target triple.
# Only targets upstream actually publishes are listed; every one of them is a
# statically linked musl build, so the packages have no library dependencies.
get_ripgrep_target() {
    local arch=$1
    case "$arch" in
        "amd64") echo "x86_64-unknown-linux-musl" ;;
        "arm64") echo "aarch64-unknown-linux-musl" ;;
        "armhf") echo "armv7-unknown-linux-musleabihf" ;;
        *)       echo "" ;;
    esac
}

# Function to build for a specific architecture
build_architecture() {
    local build_arch=$1
    local target
    local ripgrep_release

    target=$(get_ripgrep_target "$build_arch")
    if [ -z "$target" ]; then
        echo "❌ Unsupported architecture: $build_arch"
        echo "Supported architectures: amd64, arm64, armhf"
        return 1
    fi

    ripgrep_release="ripgrep-$build_arch"
    local asset="ripgrep-${ripgrep_VERSION}-${target}"

    echo "Building for architecture: $build_arch using $asset"

    # Clean up any previous downloads for this architecture
    rm -rf "$ripgrep_release" || true
    rm -f "${asset}.tar.gz" || true

    # Download and extract the ripgrep bundle for this architecture. The tarball
    # has a top-level <asset>/ directory, so strip it into a per-arch folder.
    if ! wget "https://github.com/BurntSushi/ripgrep/releases/download/${ripgrep_VERSION}/${asset}.tar.gz"; then
        echo "❌ Failed to download ripgrep binary for $build_arch"
        return 1
    fi

    mkdir -p "$ripgrep_release"
    if ! tar -xf "${asset}.tar.gz" -C "$ripgrep_release" --strip-components=1; then
        echo "❌ Failed to extract ripgrep binary for $build_arch"
        return 1
    fi

    rm -f "${asset}.tar.gz"

    # amd64/arm64/armhf are release architectures on every supported Ubuntu.
    declare -a arr=("jammy" "noble" "questing" "resolute")

    for dist in "${arr[@]}"; do
        FULL_VERSION="$ripgrep_VERSION-${BUILD_VERSION}~${dist}_${build_arch}_ubu"
        echo "  Building $FULL_VERSION"

        if ! docker build . -f Dockerfile.ubu -t "ripgrep-ubuntu-$dist-$build_arch" \
            --build-arg UBUNTU_DIST="$dist" \
            --build-arg ripgrep_VERSION="$ripgrep_VERSION" \
            --build-arg BUILD_VERSION="$BUILD_VERSION" \
            --build-arg FULL_VERSION="$FULL_VERSION" \
            --build-arg ARCH="$build_arch" \
            --build-arg RG_RELEASE="$ripgrep_release" \
            --build-arg BUILD_DATE="$BUILD_DATE"; then
            echo "❌ Failed to build Docker image for $dist on $build_arch"
            return 1
        fi

        id="$(docker create "ripgrep-ubuntu-$dist-$build_arch")"
        if ! docker cp "$id:/ripgrep_$FULL_VERSION.deb" - > "./ripgrep_$FULL_VERSION.deb"; then
            echo "❌ Failed to extract .deb package for $dist on $build_arch"
            return 1
        fi

        if ! tar -xf "./ripgrep_$FULL_VERSION.deb"; then
            echo "❌ Failed to extract .deb contents for $dist on $build_arch"
            return 1
        fi
    done

    # Clean up extracted directory
    rm -rf "$ripgrep_release" || true

    echo "✅ Successfully built for $build_arch"
    return 0
}

# Main build logic
if [ "$ARCH" = "all" ]; then
    echo "🚀 Building ripgrep $ripgrep_VERSION-$BUILD_VERSION for all supported architectures..."
    echo ""

    # All supported architectures
    ARCHITECTURES=("amd64" "arm64" "armhf")

    for build_arch in "${ARCHITECTURES[@]}"; do
        echo "==========================================="
        echo "Building for architecture: $build_arch"
        echo "==========================================="

        if ! build_architecture "$build_arch"; then
            echo "❌ Failed to build for $build_arch"
            exit 1
        fi

        echo ""
    done

    echo "🎉 All architectures built successfully!"
    echo "Generated packages:"
    ls -la ripgrep_*.deb
else
    # Build for single architecture
    if ! build_architecture "$ARCH"; then
        exit 1
    fi
fi
