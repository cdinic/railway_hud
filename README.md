# Railway HUD

A native macOS menu bar app that shows the live deployment status of your [Railway](https://railway.app) project as retro LED indicators.

![menu bar LEDs showing green/red status]

## What it does

- Displays a row of colored LEDs in the menu bar — one per service
- Click the LEDs to open a panel listing all services and their statuses
- Click any service row to open it in the Railway console
- Drag to reorder services in the panel
- Polls for updates every 30 seconds

**LED colors:**
| Color | Meaning |
|-------|---------|
| Green | Live / success |
| Blue | Deploying |
| Yellow | Queued |
| Red | Failed / down |
| Gray | No deployments / unknown |

## Requirements

- macOS 13+
- Xcode with Swift toolchain
- A [Railway](https://railway.app) account and API token

## Setup

**1. Get a Railway API token**

Go to [railway.app](https://railway.app) → Account Settings → Tokens → generate a new token.

**2. Build and run**

```bash
git clone https://github.com/cdinic/railway_hud.git
cd railway_hud
./build.sh
open RailwayHUD.app
```

**3. Enter your credentials**

Click the LEDs in the menu bar → click **settings** → enter your API token and Project ID → Save & Connect.

Your Project ID is in the URL when viewing your project on railway.app: `railway.app/project/<project-id>`.
