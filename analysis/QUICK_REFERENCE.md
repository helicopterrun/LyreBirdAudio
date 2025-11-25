# LyreBird Analysis Tools - Quick Reference

## Stream Quality Analysis

```bash
# Basic 30-second test
python3 lyrebird_stream_analyzer.py -d 30

# Production analysis (5 minutes with export)
python3 lyrebird_stream_analyzer.py -d 300 -o quality.png -j quality.json

# What to look for:
# - Bird stream median SNR >40 dB (excellent), >30 dB (good), <20 dB (needs work)
# - Std dev <5 dB (consistent), >10 dB (inconsistent, investigate)
# - Filter improvement >15 dB per stage (effective)
```

## BirdNET Detection Summary

```bash
# Last 24 hours
python3 birdnet_analyzer.py --url http://192.168.1.37:8080 --hours 24

# With visualization
python3 birdnet_analyzer.py --url http://192.168.1.37:8080 \
  --hours 24 --export detections.json --plot timeline.png

# Filter by confidence
python3 birdnet_analyzer.py --url http://192.168.1.37:8080 \
  --min-confidence 0.8 --hours 24
```

## Quality-Detection Correlation

```bash
# Analyze last hour (quick check)
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/birdnet-go/clips \
  --hours 1

# Full 24-hour analysis
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/birdnet-go/clips \
  --hours 24 \
  --output correlation.png \
  --json correlation.json

# What to look for:
# - Correlation r >0.5 (strong - quality matters!)
# - Correlation r <0.3 (weak - other factors dominate)
# - Species with low SNR (need attention)
# - SNR range of successful detections (your baseline target)
```

## Common Workflows

### Daily Health Check
```bash
# Morning routine - analyze yesterday
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/clips --hours 24 \
  --output ~/daily/$(date +%Y%m%d).png
```

### Before/After Testing
```bash
# BEFORE changing something
python3 lyrebird_stream_analyzer.py -d 300 -j before.json

# AFTER change
python3 lyrebird_stream_analyzer.py -d 300 -j after.json

# Compare the median SNR and std dev values
```

### Species Investigation
```bash
# Why am I not detecting House Finches?
python3 birdnet_analyzer.py --url http://192.168.1.37:8080 \
  --species "House Finch" --hours 168

# Check their SNR in detections
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/clips --hours 168 --json finch.json

# Then examine: cat finch.json | jq '.clip_analysis | 
#   to_entries | map(select(.value.species == "House Finch"))'
```

## Interpreting Results

### Stream Analysis
```
✓ GOOD:     Bird SNR >40 dB, std <5 dB, improvements >15 dB
⚠ OKAY:     Bird SNR 30-40 dB, std 5-10 dB
❌ PROBLEM: Bird SNR <30 dB, std >10 dB, or negative improvements
```

### Detection Correlation
```
✓ GOOD:     correlation >0.5, species SNR >35 dB
⚠ OKAY:     correlation 0.3-0.5, species SNR 25-35 dB  
❌ PROBLEM: species SNR <25 dB consistently
```

### Quick Diagnosis

| Symptom | Likely Cause | Solution |
|---------|-------------|----------|
| Low bird stream SNR | Poor isolation or bad filter | Check mounting, adjust filters |
| High std dev | Environmental (wind/traffic) | Improve isolation, time analysis |
| Low correlation | BirdNET robust OR quality uniform | May be okay, investigate outliers |
| Species with low SNR | Distance or quiet calls | Reposition mic, lower threshold |
| Afternoon SNR drop | Wind or traffic pattern | Schedule recording/analysis |

## File Locations

```bash
# Stream analyzer
~/projects/lyrebird/lyrebird_stream_analyzer.py

# BirdNET API tool
~/projects/lyrebird/birdnet_analyzer.py

# Correlation tool
~/projects/lyrebird/lyrebird_detection_correlator.py

# BirdNET clips (find with):
find ~ -name "*.wav" -path "*/birdnet*" -mtime -1
```

## API Endpoints (BirdNET-Go)

```bash
# Test connection
curl http://192.168.1.37:8080/api/detections?limit=1

# Get recent detections
curl http://192.168.1.37:8080/api/detections?limit=100

# Filter by confidence
curl http://192.168.1.37:8080/api/detections?minConfidence=0.8

# Species list
curl http://192.168.1.37:8080/api/species
```

## Dependencies

```bash
# Install everything
pip3 install numpy scipy matplotlib requests pandas

# Or use requirements.txt
pip3 install -r requirements.txt
```

## Getting Help

```bash
# Built-in help for any tool
python3 lyrebird_stream_analyzer.py --help
python3 birdnet_analyzer.py --help
python3 lyrebird_detection_correlator.py --help

# Version info
python3 lyrebird_stream_analyzer.py --version
```

## Your Excellent Results (Reference)

From your test run:
- **Bird stream median SNR: 52.2 dB** ← Excellent!
- **Std dev: 2.1 dB** ← Very consistent!
- **Filter improvement: +61.4 dB** ← Crushing it!
- **Low freq reduction: -36.1 dB** ← Great isolation!

This is your baseline. Future tests should maintain or exceed these numbers.
