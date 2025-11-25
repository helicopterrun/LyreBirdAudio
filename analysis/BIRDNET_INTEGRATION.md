# BirdNET-Go Integration Guide

Complete guide for analyzing BirdNET detections with your LyreBird audio system.

## Overview

You now have three tools that work together:

1. **`lyrebird_stream_analyzer.py`** - Analyzes live RTSP audio streams
2. **`birdnet_analyzer.py`** - Fetches and analyzes BirdNET-Go detections via API
3. **`lyrebird_detection_correlator.py`** - Correlates audio quality with detection confidence

## Tool 1: BirdNET API Analyzer

Fetches detections from BirdNET-Go and provides detailed analysis.

### Basic Usage

```bash
# Fetch and analyze recent detections
python3 birdnet_analyzer.py --url http://192.168.1.37:8080

# Last 24 hours with minimum confidence
python3 birdnet_analyzer.py --url http://192.168.1.37:8080 \
  --hours 24 --min-confidence 0.7

# Specific species only
python3 birdnet_analyzer.py --url http://192.168.1.37:8080 \
  --species "American Robin"

# Export to JSON for further analysis
python3 birdnet_analyzer.py --url http://192.168.1.37:8080 \
  --export detections.json

# Create timeline visualization
python3 birdnet_analyzer.py --url http://192.168.1.37:8080 \
  --plot timeline.png
```

### What It Shows

- Total detections and unique species
- Confidence statistics (mean, median, range)
- Time range and duration
- Top detected species
- Hourly detection distribution
- Confidence distribution by bins

### Example Output

```
================================================================================
BIRDNET-GO DETECTION SUMMARY
================================================================================

Total Detections: 342
Unique Species:   28

Time Range:
  Start:    2025-01-15 06:23:14
  End:      2025-01-15 18:47:09
  Duration: 12.4 hours

Confidence Statistics:
  Mean:     0.842
  Median:   0.873
  Std Dev:  0.124
  Range:    0.512 to 0.989

Top 15 Detected Species:
   1. American Robin                   87 (25.4%)
   2. Song Sparrow                     52 (15.2%)
   3. Dark-eyed Junco                  41 (12.0%)
   ...
```

## Tool 2: Detection Quality Correlator

**This is the powerful one** - it analyzes the actual audio clips from detections and correlates SNR with confidence scores.

### Setup

First, you need to know where BirdNET-Go stores audio clips. Typically:
- Default: `/path/to/birdnet-go/clips/`
- Or check your BirdNET-Go config file

### Usage

```bash
# Analyze last hour of detections
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/birdnet-go/clips \
  --hours 1

# Longer analysis with saved output
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/birdnet-go/clips \
  --hours 6 \
  --output correlation_analysis.png \
  --json correlation_data.json
```

### What It Reveals

This tool answers critical questions:

1. **What SNR do you need for good detections?**
   - If most high-confidence detections have SNR > 40 dB, that's your target
   - If you see good detections at SNR 20-30 dB, your current quality is sufficient

2. **Which species are harder to detect?**
   - Species with lower average SNR might need:
     - Better microphone positioning
     - Different filter settings
     - Higher confidence thresholds

3. **Is there correlation?**
   - Strong correlation (r > 0.5): Audio quality is critical
   - Weak correlation (r < 0.3): BirdNET is handling noise well, or other factors dominate

4. **When does quality degrade?**
   - Check SNR by time of day
   - Identify patterns (traffic noise during rush hour, wind in afternoon)

### Example Insights

```
Correlation (SNR vs Confidence): 0.673
  ✓ Strong correlation - audio quality significantly affects detection confidence

Species Analysis:
  American Robin:     avg SNR 45.2 dB, avg conf 0.89 (87 detections)
  House Sparrow:      avg SNR 32.1 dB, avg conf 0.74 (34 detections)
  ← House Sparrow needs better quality or closer mic placement
```

## Complete Workflow Example

Here's how to use all three tools together to optimize your system:

### Step 1: Check Current Audio Quality

```bash
# Run 5-minute stream analysis
python3 lyrebird_stream_analyzer.py -d 300 -o stream_quality.png -j stream_data.json
```

**Look for:**
- Bird stream median SNR (want >40 dB)
- Low std dev (want <5 dB for consistency)
- Good filter effectiveness (>15 dB improvement per stage)

### Step 2: Analyze Recent Detections

```bash
# Fetch last 24 hours of detections
python3 birdnet_analyzer.py \
  --url http://192.168.1.37:8080 \
  --hours 24 \
  --export recent_detections.json \
  --plot detection_timeline.png
```

**Look for:**
- How many detections per hour
- Average confidence scores
- Are there species you expect but aren't seeing?

### Step 3: Correlate Quality with Detections

```bash
# Analyze actual detection clips
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/birdnet-go/clips \
  --hours 6 \
  --output quality_correlation.png \
  --json correlation_results.json
```

**Look for:**
- SNR of successful detections (this is your baseline)
- Species that have consistently low SNR (need attention)
- Correlation strength (how critical is audio quality?)

### Step 4: Interpret and Optimize

#### Scenario A: High Stream SNR, Low Detection Confidence

```
Stream analysis: Bird stream median SNR = 52 dB ✓
Detection analysis: Average detection SNR = 28 dB ⚠
```

**Problem:** Your live streams are great, but recorded clips have low quality.
**Solutions:**
- Check BirdNET-Go recording settings
- Verify which stream BirdNET is using (should use 'bird' stream)
- Check disk I/O during recording

#### Scenario B: Low SNR for Specific Species

```
American Robin: avg SNR 48 dB, conf 0.91 ✓
House Finch:    avg SNR 22 dB, conf 0.68 ⚠
```

**Problem:** House Finch calls might be quieter or more distant.
**Solutions:**
- Adjust microphone position/direction
- Consider adding a second microphone
- Lower confidence threshold specifically for House Finch if it's important

#### Scenario C: Time-Based Quality Degradation

```
Morning (6-9am):   SNR 52 dB, conf 0.88 ✓
Afternoon (2-5pm): SNR 31 dB, conf 0.72 ⚠
```

**Problem:** Quality drops during afternoon (probably wind or traffic).
**Solutions:**
- Improve wind isolation
- Adjust filter for time of day
- Focus analysis on morning hours when quality is best

## Finding Your BirdNET Clips Directory

If you're not sure where clips are stored:

```bash
# Check BirdNET-Go config
cat /path/to/birdnet-go/config.yaml | grep -i clip

# Or search for recent WAV files
find ~ -name "*.wav" -mtime -1 | grep -i bird

# Common locations:
# - /var/lib/birdnet-go/clips/
# - ~/birdnet-go/clips/
# - /opt/birdnet-go/clips/
```

## Advanced: Continuous Monitoring

### Daily Quality Report

Create a script to run daily analysis:

```bash
#!/bin/bash
# daily_analysis.sh

DATE=$(date +%Y-%m-%d)
CLIPS_DIR="/path/to/birdnet-go/clips"

# Analyze yesterday's detections
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips $CLIPS_DIR \
  --hours 24 \
  --output ~/reports/quality_$DATE.png \
  --json ~/reports/quality_$DATE.json

# Alert if SNR drops below threshold
python3 -c "
import json
with open('~/reports/quality_$DATE.json') as f:
    data = json.load(f)
    if data['correlation_stats'].get('snr_range', [0, 0])[0] < 30:
        print('WARNING: Low SNR detected!')
"
```

### Seasonal Comparison

```bash
# Summer detections
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/clips \
  --hours 168 \
  --output summer_quality.png

# Winter detections  
python3 lyrebird_detection_correlator.py \
  --url http://192.168.1.37:8080 \
  --clips /path/to/clips \
  --hours 168 \
  --output winter_quality.png

# Compare the results to see seasonal differences
```

## Troubleshooting

### "Could not connect to BirdNET-Go server"

```bash
# Test the API manually
curl http://192.168.1.37:8080/api/detections?limit=1

# Check if BirdNET-Go is running
ps aux | grep birdnet

# Check firewall
sudo ufw status | grep 8080
```

### "No audio clips could be analyzed"

```bash
# Verify clips directory
ls -lh /path/to/birdnet-go/clips/ | head

# Check permissions
stat /path/to/birdnet-go/clips/

# Verify clip format (should be WAV)
file /path/to/birdnet-go/clips/*.wav | head
```

### "Correlation is very weak"

This might actually be good! It could mean:
- BirdNET is robust to noise (handles varying quality well)
- Your current quality is "good enough" across the board
- Other factors (species rarity, call volume, background complexity) matter more

## Integration with Home Assistant

If you use Home Assistant:

```yaml
# automation.yaml
automation:
  - alias: "Bird Detection Quality Monitor"
    trigger:
      - platform: time
        at: "09:00:00"
    action:
      - service: shell_command.analyze_bird_quality
      - service: notify.notify
        data:
          message: "Daily bird detection analysis complete"
          
shell_command:
  analyze_bird_quality: >
    python3 /path/to/lyrebird_detection_correlator.py
    --url http://192.168.1.37:8080
    --clips /path/to/clips
    --hours 24
    --json /tmp/quality.json
```

## Next Steps

1. **Run initial analysis** to establish baseline
2. **Make one change** (new filter, mic position, etc.)
3. **Re-analyze** to see impact
4. **Iterate** based on results

The key insight is seeing the **actual SNR of successful detections** - this tells you exactly what quality you need to maintain!
