# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
  echo "📦 安装 sing-box..."

  ARCH=$(dpkg --print-architecture)

  case "$ARCH" in
    amd64)
      SB_ARCH="amd64"
      ;;
    arm64)
      SB_ARCH="arm64"
      ;;
    *)
      echo "❌ 不支持架构: $ARCH"
      exit 1
      ;;
  esac

  VERSION="1.12.0"

  URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_linux_${SB_ARCH}.deb"

  echo "⬇️ 下载: $URL"

  curl -fL -o /tmp/sing-box.deb "$URL"

  dpkg -i /tmp/sing-box.deb
fi
