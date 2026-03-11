# HQ Outages Animation

Time-based animation visualization of Hydro-Québec power outages showing raw polygon data appearing and disappearing over time.

## Features

- 📅 **Week-by-week playback** - Select any week to view outage progression
- ⏯️ **Playback controls** - Play/pause with adjustable speed (1x, 2x, 5x, 10x)
- 🗺️ **Interactive map** - Zoom and pan across Quebec
- 🔍 **Address search** - Find specific locations using Mapbox geocoder
- 📊 **Real-time stats** - See active outage count at each timestamp

## Live Demo

https://evelynebrie.github.io/hq-outages-animation/

## How It Works

### Data Processing

1. Workflow downloads polygon files from Dropbox
2. Groups files by week (Monday-Sunday)
3. Combines each week's polygons into a single JSON file
4. Each polygon includes its timestamp for animation

### Visualization

- Week selector loads pre-processed data file
- Time slider scrubs through 15-minute intervals
- Polygons appear/disappear based on current time
- Smooth playback at configurable speeds

## Usage

### Running the Workflow

1. Go to Actions tab in GitHub
2. Select "Process Animation Data"
3. Click "Run workflow"
4. Optionally specify number of weeks to process (default: 4)
5. Wait for processing to complete (~30-60 min for 4 weeks)
6. View updated animation at GitHub Pages URL

### Viewing the Animation

1. Open https://evelynebrie.github.io/hq-outages-animation/
2. Select a week from the dropdown
3. Use play/pause and speed controls
4. Drag slider to jump to specific time
5. Search for addresses or zoom to explore

## Data Source

Polygon data from Hydro-Québec outage scraper:
- Scraped every 15 minutes
- Stored in Dropbox (`/hq-outages/`)
- Raw outage polygon geometries

## Technical Stack

- **Map**: Mapbox GL JS
- **Data Processing**: R (sf, dplyr, jsonlite)
- **Workflow**: GitHub Actions
- **Deployment**: GitHub Pages

## Configuration

### Secrets Required

- `DROPBOX_REFRESH_TOKEN`
- `DROPBOX_APP_KEY`
- `DROPBOX_APP_SECRET`

(Same as main hq-outages repo)

### Mapbox Token

Public token embedded in `index.html`:
```javascript
mapboxgl.accessToken = 'pk.eyJ1IjoiZXZlbHluZWJyaWUiLCJhIjoiY2themE5OGF2MDdxazJybG9oNzUyaXoxNSJ9.njPe2lcTp82DKjDeGkHaQA';
```

## File Structure

```
hq-outages-animation/
├── .github/workflows/
│   └── process-animation-data.yml   # Data processing workflow
├── process_animation_data.R          # R script to process polygons
├── index.html                        # Animation visualization
├── public/data/                      # Generated data (not in git)
│   ├── weeks.json                    # Index of available weeks
│   ├── week_2026-03-03.json         # Week data files
│   └── week_2026-03-10.json
└── README.md
```

## Development

To update the animation:
1. Make changes to `index.html` or `process_animation_data.R`
2. Commit and push
3. Run workflow to regenerate data
4. Changes deploy automatically to GitHub Pages

## License

MIT
