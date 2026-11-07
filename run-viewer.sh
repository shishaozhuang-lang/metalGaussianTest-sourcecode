#!/bin/zsh
# 一键启动渲染：编译（如需）+ 启动 SampleApp 渲染指定模型。
#
# 用法:
#   ./run-viewer.sh                          # 默认渲染 PLYIO/hailuo/point_cloud.ply
#   ./run-viewer.sh <model.ply|splat|spz>    # 渲染任意 splat 文件
#   ./run-viewer.sh --morton                 # 渲染 hailuo 的 Morton 排序版本
#   ./run-viewer.sh --perf[=CSV路径]         # 附加性能记录（自动旋转+每帧CSV）
#   ./run-viewer.sh --rebuild                # 强制重新编译
#
# 模型旁的 view.json 自动作为初始视角（支持 pose_semantics: "camera_world"）。

set -euo pipefail

repo_dir="${0:A:h}"
project="$repo_dir/SampleApp/MetalSplatter_SampleApp.xcodeproj"
scheme="MetalSplatter SampleApp"

model=""
extra_args=()
force_build=false

default_model="$repo_dir/PLYIO/hailuo/point_cloud.ply"
morton_model="$repo_dir/PLYIO/hailuo/point_cloud_morton.ply"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --morton)
            model="$morton_model"
            shift
            ;;
        --perf)
            extra_args+=("--perf")
            shift
            ;;
        --perf=*)
            extra_args+=("$1")
            shift
            ;;
        --rebuild)
            force_build=true
            shift
            ;;
        -*)
            extra_args+=("$1")
            shift
            ;;
        *)
            if [[ -z "$model" ]]; then
                model="$1"
            else
                extra_args+=("$1")
            fi
            shift
            ;;
    esac
done

[[ -z "$model" ]] && model="$default_model"

if [[ ! -f "$model" ]]; then
    echo "错误: 找不到模型文件 $model" >&2
    exit 1
fi

# 定位上次构建产物；不存在或源码有更新时重新编译
app_path=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*MetalSplatter_SampleApp*/Build/Products/Release/MetalSplatter SampleApp.app" \
    -maxdepth 6 2>/dev/null | head -1)

needs_build=true
if [[ -n "$app_path" && -d "$app_path" && "$force_build" == false ]]; then
    # 任一源码文件比二进制新则重新编译
    binary="$app_path/Contents/MacOS/MetalSplatter SampleApp"
    if [[ -f "$binary" ]] && \
       ! find SampleApp MetalSplatter SplatIO PLYIO SampleBoxRenderer SplatConverter \
              -name "*.swift" -newer "$binary" 2>/dev/null | head -1 | grep -q .; then
        needs_build=false
    fi
fi

if [[ "$needs_build" == true ]]; then
    echo "==> 编译 Release 版本..."
    xcodebuild -project "$project" \
        -scheme "$scheme" \
        -configuration Release \
        -destination 'platform=macOS' \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" | head -20
    app_path=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*MetalSplatter_SampleApp*/Build/Products/Release/MetalSplatter SampleApp.app" \
        -maxdepth 6 2>/dev/null | head -1)
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        echo "错误: 编译产物未找到" >&2
        exit 2
    fi
else
    echo "==> 使用现有构建: $app_path"
fi

# 清理上次会话残留的窗口状态，避免恢复出多个重复窗口
defaults delete com.shichen.metalsplatter.sampleapp 2>/dev/null || true
saved_state="$HOME/Library/Saved Application State/com.shichen.metalsplatter.sampleapp.savedState"
[[ -d "$saved_state" ]] && rm -rf "$saved_state"

view_json="$(dirname "$model")/view.json"
if [[ -f "$view_json" ]]; then
    echo "==> 初始视角: $view_json"
else
    echo "==> 未找到 view.json，使用默认相机位姿"
fi

echo "==> 启动渲染: $model"
exec "$app_path/Contents/MacOS/MetalSplatter SampleApp" \
    --model "$model" \
    ${extra_args:+$extra_args}
