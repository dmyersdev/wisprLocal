# WisprLocal

WisprLocal is a macOS menu bar dictation app that records audio, sends it to OpenAI for transcription, and pastes text into the active app.

## Requirements

- macOS 13.0+
- Xcode 15+
- An OpenAI API key

## Run Locally (Xcode)

1. Clone the repo:

   ```bash
   git clone https://github.com/dmyersdev/wisprLocal.git
   cd wisprLocal
   ```

2. Open the project in Xcode:

   ```bash
   open WisprLocal.xcodeproj
   ```

3. In Xcode, set signing:
   - Select target `WisprLocal`
   - Go to `Signing & Capabilities`
   - Pick your Team
   - (Optional) change bundle ID from `com.example.WisprLocal`

4. Build and run with the `WisprLocal` scheme.

5. On first run, grant permissions when prompted:
   - Microphone
   - Accessibility (required to paste into other apps)
   - Input Monitoring (needed for Fn hold-to-talk mode)

6. Configure your API key:
   - Click the menu bar icon
   - Open `Settings...`
   - Paste your OpenAI API key (`sk-...`) and click `Save`

## Build From Terminal

```bash
xcodebuild \
  -project WisprLocal.xcodeproj \
  -scheme WisprLocal \
  -configuration Release \
  -derivedDataPath ./.derived \
  build
```

Built app path:

```text
./.derived/Build/Products/Release/WisprLocal.app
```

## Download Options

### 1) Download a prebuilt app (if a release exists)

Go to:

- https://github.com/dmyersdev/wisprLocal/releases

Download the latest `.zip`/`.dmg` and move `WisprLocal.app` into `/Applications`.

### 2) Download source and build it yourself

If no release artifact is available:

1. Open the repository page: https://github.com/dmyersdev/wisprLocal
2. Click `Code` -> `Download ZIP`
3. Unzip and follow the run/build instructions above

## Create a ZIP for distribution

After building in Release:

```bash
ditto -c -k --keepParent \
  ./.derived/Build/Products/Release/WisprLocal.app \
  WisprLocal-macOS.zip
```

You can upload `WisprLocal-macOS.zip` to a GitHub Release for easy downloads.
