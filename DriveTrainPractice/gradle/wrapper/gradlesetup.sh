#!/bin/bash
set -euo pipefail
MCDIR="$HOME/Documents/MCSEHS"
LAUNCHER_DIR="$MCDIR/ATLauncher"
NATIVES_DIR="$MCDIR/lwjgl-arm64-natives"
JARS_DIR="$MCDIR/lwjgl-arm64-jars"

# TODO
#  Incrementally install java depending on launched version instead of initilization
# Edit backup settings more
# Find a way to do LGJWL 2 and LGJWL 1.17


install_java() {
  local JAVA_DIR="$MCDIR/Java$1"
  [ -d "$JAVA_DIR" ] && return
  local ARCH
  [[ "$(uname -m)" == "arm64" ]] && ARCH="aarch64" || ARCH="x64"
  # The line below makes it so Java 8 is always x64, because MC doesnt support ARM with Java 8 on older versions. It automatically installs rosetta on ARM macs for compatibility with x64 Java 8
  [[ "$1" == "8" ]] && {
    ARCH="x64"
    softwareupdate --install-rosetta --agree-to-license 2>/dev/null || true
  }
  osascript -e "display dialog \"Installing Java $1...\nThis one-time process takes a moment.\" buttons {\"OK\"} default button \"OK\" with title \"Java Installer\"" &
  local DIALOG=$!
  mkdir -p "$JAVA_DIR" #Also creates MCDIR if it doesn't exist
  curl -fsSL -o /tmp/java-corretto.tar.gz "https://corretto.aws/downloads/latest/amazon-corretto-${1}-${ARCH}-macos-jdk.tar.gz"
  tar -xzf /tmp/java-corretto.tar.gz -C "$JAVA_DIR" --strip-components=1
  rm /tmp/java-corretto.tar.gz
  kill $DIALOG 2>/dev/null
}

# ATLauncher doesn't bundle ARM natives for LWJGL 1.17-1.18.2, so we have to do it ourselves. Only do this on ARM Macs, x86 can use the bundled x64 natives just fine.
install_lwjgl_arm64() {
  [[ "$(uname -m)" != "arm64" || -f "$NATIVES_DIR/liblwjgl.dylib" ]] && return
  echo "Installing ARM64 LWJGL natives and jars..."
  rm -rf "$NATIVES_DIR" "$JARS_DIR"
  mkdir -p "$NATIVES_DIR" "$JARS_DIR"
  local BASE="https://repo1.maven.org/maven2/org/lwjgl"
  local VER="3.3.1"
  for module in lwjgl lwjgl-glfw lwjgl-openal lwjgl-opengl lwjgl-stb lwjgl-jemalloc lwjgl-tinyfd; do
    # Download the Java jar (classes)
    curl -fsSL -o "$JARS_DIR/${module}-${VER}.jar" "${BASE}/${module}/${VER}/${module}-${VER}.jar"
    # Download the ARM64 native jar and extract dylibs
    curl -fsSL -o /tmp/lwjgl-native.jar "${BASE}/${module}/${VER}/${module}-${VER}-natives-macos-arm64.jar"
    unzip -q -o -j /tmp/lwjgl-native.jar "*.dylib" -d "$NATIVES_DIR"
    rm /tmp/lwjgl-native.jar
  done
}
##################################### DO NOT QUOTIZE CAT FILE INSERTIONS NO 'FOO', ONLY FOO
# Minecraft enforces LWJGL x86_64 binaries even with arm support + Java arm64 17 on 1.17-1.18.2, the LWJGL loader overrides this but its broken. Do not use rosetta for 1.17-1.18.2 as its emulated performance
install_launcher() {
  [[ -f "$LAUNCHER_DIR/ATLauncher.jar" && -f "$LAUNCHER_DIR/configs/ATLauncher.json" ]] && return
  mkdir -p "$LAUNCHER_DIR/configs" #Also creates LAUNCHER_DIR if it doesn't exist
  curl -fsSL -o "$LAUNCHER_DIR/ATLauncher.jar" "$(curl -s https://api.github.com/repos/ATLauncher/ATLauncher/releases/latest | grep -o 'https://[^"]*\.jar')"
  cat >"$LAUNCHER_DIR/configs/ATLauncher.json" <<SETTINGS
{
  "firstTimeRun": false,
  "selectedTabOnStartup": 3,
  "useJavaProvidedByMinecraft": false,
  "usingCustomJavaPath": true,
  "ignoreJavaOnInstanceLaunch": true,
  "javaPath": "${MCDIR}/JavaWrapper/Contents/Home",
  "keepLauncherOpen": true,
  "enableConsole": false,
  "useRecycleBin": true,
  "maximumMemory": 4096,
  "enableAnalytics": false,
  "enableAutomaticBackupAfterLaunch": true,
  "backupMode": "NORMAL",
  "defaultInstanceSorting": "BY_LAST_PLAYED",
  "theme": "com.atlauncher.themes.OneDark"
}
SETTINGS
}

# Writes a thin Java shim that ATLauncher calls for every instance launch.
# The shim reads instance.json to find the required Java version, then exec's
# into the correct Corretto — leaving zero memory/CPU overhead while playing.
# ATLauncher will say executing with appended args, but its usually not actually being executed as this does this action and can choose whether to carry those args or not. Misleading eh
create_wrapper() {
  local bin="$MCDIR/JavaWrapper/Contents/Home/bin"
  mkdir -p "$bin"
  cat >"$bin/java" <<'WRAPPER' # quoted as of now
#!/bin/bash
MCDIR="$HOME/Documents/MCSEHS"
NATIVES="$MCDIR/lwjgl-arm64-natives"
JARS="$MCDIR/lwjgl-arm64-jars"
for arg in "$@"; do
  [[ "$arg" == *"/ATLauncher/instances/"* ]] || continue
  instance="${arg#*/ATLauncher/instances/}"
  json="$MCDIR/ATLauncher/instances/${instance%%/*}/instance.json"
  JAVA_VER=$(grep '"majorVersion"' "$json" | head -1 | sed -E 's/.*:[[:space:]]*([0-9]+).*/\1/')
  MC_VER=$(grep '"id"' "$json" | head -1 | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  [[ -z "$JAVA_VER" ]] && JAVA_VER=8
  break
done
# Force Java 17 for Minecraft 1.17 (needs 16, but 17 works perfectly)
[[ "$MC_VER" == 1.17* ]] && JAVA_VER=17
if [[ "$(uname -m)" == "arm64" && "$JAVA_VER" == "17" && "$MC_VER" == 1.1[78]* && -d "$NATIVES" && -d "$JARS" ]]; then
new_args=()
cp_next=false
for arg in "$@"; do
  if $cp_next; then
    IFS=':' read -ra cp_entries <<< "$arg"
    new_cp=()
    for entry in "${cp_entries[@]}"; do
      [[ "$entry" != *"/org/lwjgl/"* ]] && new_cp+=("$entry")
    done
    for jar in "$JARS"/*.jar; do new_cp+=("$jar"); done
    new_args+=("$(IFS=:; echo "${new_cp[*]}")")
    cp_next=false
  elif [[ "$arg" == -Djava.library.path=* ]]; then
    new_args+=("-Djava.library.path=$NATIVES")
  elif [[ "$arg" == "-cp" ]]; then
    new_args+=("$arg")
    cp_next=true
  else
    new_args+=("$arg")
  fi
done
set -- "${new_args[@]}"
fi

printf "###===========================================================###"
printf >&2 "[SHIM] EXECUTING JAVA RUNTIME: %s\n" "$MCDIR/Java${JAVA_VER}/Contents/Home/bin/java"
printf >&2 "[SHIM] ACTUAL JVM ARGUMENTS: %s\n" "$*"
exec "$MCDIR/Java${JAVA_VER}/Contents/Home/bin/java" "$@"
WRAPPER
  chmod +x "$bin/java"
}

while true; do
  ACTION=$(osascript -e 'button returned of (display dialog "NEW UPDATE: Click Run Diagnostic ONCE.\nClick Launch to launch ATLauncher for minecraft.\nATLauncher lets you create and manage Minecraft instances.\n\nGetting started:\n• Sign in via Accounts tab with your Microsoft account\n• Go to Packs/Create Packs to start an instance\n• Pick a version/modpack and go through installation\n• Go back to instances and press play.\n\nEach instance is separate, allowing to manage different modpacks or versions. You can also install individual mods depending on the version and modloader." buttons {"Quit", "Run Diagnostic", "Launch"} default button "Launch" with title "Welcome to MCSEHS")')
  case "$ACTION" in
  "Quit")
    exit 0
    ;;
  "Run Diagnostic")
    rm -rf "$MCDIR"/Java*
    rm -rf "$LAUNCHER_DIR"/configs/ATLauncher.json
    rm -rf "$LAUNCHER_DIR"/ATLauncher.jar
    rm -rf "$MCDIR"/lwjgl-arm64*
    osascript -e 'display dialog "Diagnostic Completed.\nEmail xploczx@gmail.com about issues in detail if you encounter any." buttons {"OK"} default button "OK" with title "Diagnostic"'
    ;;
  "Launch") break ;;
  esac
done

for java_version in 8 17 21 25; do install_java $java_version; done
install_lwjgl_arm64
create_wrapper
install_launcher

pkill -f "ATLauncher.jar" 2>/dev/null || true
cd "$LAUNCHER_DIR"
"$MCDIR/Java21/Contents/Home/bin/java" -jar "$LAUNCHER_DIR/ATLauncher.jar" || osascript -e 'display dialog "ATLauncher failed to start. Try re-running the script. Contact xploczx@gmail.com if issue persists." buttons {"OK"} with title "SEHS Minecraft"'
# Using Java LTS versions for launcher bootup, this is the latest as of now.
