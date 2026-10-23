# BatteryFlow Official Website

This directory contains the official website / landing page for **BatteryFlow**.

## Features

- ⚡ **Pure Lightweight Architecture**: Zero heavyweight frameworks required to build or host; instantly loadable.
- 🎨 **Apple Design Language**: Glassmorphic dark slate aesthetic (#0B0F19), SF-inspired typography, and emerald/cyan accents.
- 🧪 **Interactive Power Flow Lab**: In-browser dynamic simulation of the dual-branch power Sankey diagram with real-time wattage routing and animated SVG streams.
- 🌐 **Bilingual (ZH / EN)**: Dynamic zero-reload client-side internationalization.
- 📱 **Mobile & Desktop Responsive**: Tested for 375px mobile, tablet, and 4K desktop screens.
- 🔒 **Zero Third-Party Trackers**: Privacy-preserving, fast, and secure.

## Local Preview

### Option 1: Python HTTP Server (Built-in)
```bash
cd website
python3 -m http.server 8080
# Open http://localhost:8080 in your browser
```

### Option 2: Node.js (npx serve)
```bash
cd website
npx serve . -l 8080
```

## Deployment Options

### 1. GitHub Pages (Automated via GitHub Actions)
A pre-configured GitHub Actions workflow is provided in `.github/workflows/deploy-pages.yml`.
1. Go to repository **Settings** → **Pages**.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**.
3. Push to `main` or trigger the workflow under **Actions** → **Deploy Official Website to GitHub Pages**.
4. The site will be live at `https://<username>.github.io/<repo-name>/`.

### 2. Vercel
A root `vercel.json` is pre-configured.
- **CLI**: Run `vercel` in the project root.
- **Git Integration**: Import your repository in the Vercel dashboard. Vercel detects `website` as the output directory automatically.

### 3. Cloudflare Pages
1. Go to the Cloudflare dashboard → **Workers & Pages** → **Create application** → **Pages**.
2. Connect your Git repository.
3. Configure build settings:
   - **Framework preset**: None
   - **Build command**: (leave empty)
   - **Build output directory**: `website`
4. Deploy. Free global CDN, automatic SSL, and high performance.

### 4. Docker / Self-hosted Nginx
Build and run the lightweight containerized server:
```bash
cd website
docker build -t batteryflow-website .
docker run -d -p 80:80 --name batteryflow-web batteryflow-website
```
