# How to Get eXpressO News Running on a New Computer

## What You Need
- A Mac (this was built on a Mac)
- Claude Code installed
- Internet connection

## Step-by-Step

### 1. Open Terminal and copy this whole backup folder to your new computer
USB drive, AirDrop, Google Drive, whatever works. Put it somewhere like your Desktop or Documents.

### 2. Open Terminal and run these commands (copy/paste each line):

```bash
cd ~/Desktop/EXPRESSOO-HISTORY-BACKUP
```
(or wherever you put the folder)

### 3. Install the tools you need:

```bash
# Install Node.js (needed for Netlify deploys)
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.zshrc
fnm install --lts

# Install Netlify CLI
npm install -g netlify-cli
```

### 4. Test that it works:

```bash
bash update.sh
```

This should run the full pipeline — you'll see it checking URLs and deploying. If it says "Update complete" at the end, you're good.

### 5. Open Claude Code and tell it:

> "Set up the expressoo-hourly-update scheduled task to run update.sh at 5 minutes past every hour. Auto-commit and push. Never ask for confirmation."

That's it. The site will update itself every hour.

## What's in the .env file (YOUR API KEYS — keep these secret!)

The `.env` file has 3 keys:
- **XAI_API_KEY** — your Grok/xAI API key (this is what talks to Grok to find trending posts)
- **NETLIFY_AUTH_TOKEN** — lets the script deploy to your Netlify site
- **NETLIFY_SITE_ID** — tells it which Netlify site to deploy to (groknewsx)

These are YOUR keys. Don't share them or post them publicly.

## If something breaks

Tell Claude Code: "Run bash update.sh and fix whatever's wrong." It knows the whole project.

## Your live site

https://groknewsx.netlify.app
