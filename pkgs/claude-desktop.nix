{
  lib,
  stdenvNoCC,
  fetchurl,
  electron,
  p7zip,
  icoutils,
  nodePackages,
  imagemagick,
  makeDesktopItem,
  makeWrapper,
  patchy-cnb,
}: let
  pname = "claude-desktop";
  # Using a placeholder version since the actual version might be different
  version = "latest";
  srcExe = fetchurl {
    # Downloading the latest version, without specifying version in the URL
    url = "https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe";
    hash = "sha256-nDUIeLPWp1ScyfoLjvMhG79TolnkI8hedF1FVIaPhPw=";
  };
in
  stdenvNoCC.mkDerivation rec {
    inherit pname version;

    src = ./.;

    nativeBuildInputs = [
      p7zip
      nodePackages.asar
      makeWrapper
      imagemagick
      icoutils
    ];

    desktopItem = makeDesktopItem {
      name = "claude-desktop";
      exec = "claude-desktop %u";
      icon = "claude-desktop";
      type = "Application";
      terminal = false;
      desktopName = "Claude";
      genericName = "Claude Desktop";
      categories = [
        "Office"
        "Utility"
      ];
      mimeTypes = ["x-scheme-handler/claude"];
    };

    buildPhase = ''
      runHook preBuild

      # Create temp working directory
      mkdir -p $TMPDIR/build
      cd $TMPDIR/build

      # Extract installer exe, and nupkg within it
      7z x -y ${srcExe}

      # Debug: List all extracted files to see what's available
      echo "=== Files extracted from exe ==="
      ls -la
      echo "=== End of file listing ==="

      # Look for resources directory structure
      echo "=== Checking for resources/i18n directory ==="
      find . -path "*/resources/i18n" -type d
      echo "=== End of resources/i18n check ==="

      # Try to find any .nupkg files
      echo "=== Looking for .nupkg files ==="
      find . -name "*.nupkg"
      echo "=== End of .nupkg search ==="

      # Use a very generic pattern to find any Claude nupkg file
      NUPKG_FILE=$(find . -name "*Claude*.nupkg" | head -1)
      if [ -z "$NUPKG_FILE" ]; then
        echo "ERROR: Could not find Claude nupkg file!"
        exit 1
      fi

      echo "Found nupkg file: $NUPKG_FILE"
      7z x -y "$NUPKG_FILE"

      # Package the icons from claude.exe
      wrestool -x -t 14 lib/net45/claude.exe -o claude.ico
      icotool -x claude.ico

      for size in 16 24 32 48 64 256; do
        mkdir -p $TMPDIR/build/icons/hicolor/"$size"x"$size"/apps
        install -Dm 644 claude_*"$size"x"$size"x32.png \
          $TMPDIR/build/icons/hicolor/"$size"x"$size"/apps/claude.png
      done

      rm claude.ico

      # Process app.asar files
      # We need to replace claude-native-bindings.node in both the
      # app.asar package and .unpacked directory
      mkdir -p electron-app
      cp "lib/net45/resources/app.asar" electron-app/
      cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

      cd electron-app
      asar extract app.asar app.asar.contents

      # Replace native bindings
      cp ${patchy-cnb}/lib/patchy-cnb.*.node app.asar.contents/node_modules/claude-native/claude-native-binding.node
      cp ${patchy-cnb}/lib/patchy-cnb.*.node app.asar.unpacked/node_modules/claude-native/claude-native-binding.node

      # Copy entire resources directory structure from the original app
      echo "Copying full resources directory structure..."
      if [ -d "../lib/net45/resources" ]; then
        # First remove any existing resources directory in the contents
        rm -rf app.asar.contents/resources

        # Create the resources directory
        mkdir -p app.asar.contents/resources

        # Copy all resources files and directories except app.asar and app.asar.unpacked
        find ../lib/net45/resources -type f -not -path "*/app.asar*" -exec cp --parents {} app.asar.contents/ \;

        # Ensure the i18n directory exists with at least an empty en-US.json
        mkdir -p app.asar.contents/resources/i18n
        if [ ! -f "app.asar.contents/resources/i18n/en-US.json" ]; then
          echo "Creating default en-US.json..."
          echo '{}' > app.asar.contents/resources/i18n/en-US.json
        fi
      else
        echo "ERROR: resources directory not found in original app!"
        exit 1
      fi

      # List the created resources directory for debugging
      echo "Contents of resources directory in app.asar:"
      find app.asar.contents/resources -type f | sort

      # Repackage app.asar
      echo "Repackaging app.asar..."
      asar pack app.asar.contents app.asar

      # Verify asar contents for debugging
      echo "Verifying app.asar contents:"
      asar list app.asar | grep -E "resources|i18n"

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      # Electron directory structure
      mkdir -p $out/lib/$pname
      cp -r $TMPDIR/build/electron-app/app.asar $out/lib/$pname/
      cp -r $TMPDIR/build/electron-app/app.asar.unpacked $out/lib/$pname/

      # Install icons
      mkdir -p $out/share/icons
      cp -r $TMPDIR/build/icons/* $out/share/icons

      # Install .desktop file
      mkdir -p $out/share/applications
      install -Dm0644 {${desktopItem},$out}/share/applications/$pname.desktop

      # Create wrapper
      mkdir -p $out/bin
      makeWrapper ${electron}/bin/electron $out/bin/$pname \
        --add-flags "$out/lib/$pname/app.asar" \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"

      runHook postInstall
    '';

    dontUnpack = true;
    dontConfigure = true;

    meta = with lib; {
      description = "Claude Desktop for Linux";
      license = licenses.unfree;
      platforms = platforms.unix;
      sourceProvenance = with sourceTypes; [binaryNativeCode];
      mainProgram = pname;
    };
  }
