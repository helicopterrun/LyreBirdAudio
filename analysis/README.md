# LyreBird Audio Stream Analyzer

A comprehensive tool for analyzing and optimizing RTSP audio streams for bird detection systems. Designed to work with BirdNET-Go and MediaMTX streaming infrastructure.

## Features

- 🎵 **Real-time Multi-Stream Analysis** - Simultaneously analyze raw, filtered, and bird-optimized audio streams
- 📊 **SNR Distribution Tracking** - Understand signal quality variability over time, not just averages
- 🔍 **Frequency Spectrum Analysis** - Detailed FFT analysis with focus on bird frequency range (3-8kHz)
- 📈 **Filter Effectiveness Metrics** - Quantify improvements from each filtering stage
- 🐦 **BirdNET Integration** - Correlate audio quality with detection performance (optional)
- 💾 **Export Results** - Save analysis data as JSON for further processing

## Why This Tool?

When optimizing bird detection systems, you need more than average SNR values. This analyzer provides:

- **Distribution Analysis**: See the full range of SNR values - identify if you have consistent quality or frequent dropouts
- **Time Series Visualization**: Watch SNR fluctuate with environmental conditions (wind gusts, traffic patterns)
- **Comparative Filtering**: Quantify exactly how much each filter stage improves signal quality
- **Real Bird Data**: Analyze actual bird vocalizations as captured by your BirdNET detector

## Installation

### Prerequisites

```bash
# macOS
brew install ffmpeg python@3.11

# Ubuntu/Debian
sudo apt install ffmpeg python3 python3-pip

# Install Python dependencies
pip3 install numpy scipy matplotlib
```

### Optional: BirdNET CSV Analysis

```bash
pip3 install pandas
```

## Usage

### Basic Analysis

```bash
# Analyze streams for 30 seconds
python3 lyrebird_stream_analyzer.py -d 30

# Save plot to file
python3 lyrebird_stream_analyzer.py -d 60 -o ~/Desktop/analysis.png

# Export results as JSON
python3 lyrebird_stream_analyzer.py -d 60 -j results.json
```

### Custom Stream URLs

```bash
python3 lyrebird_stream_analyzer.py \
  -s raw=rtsp://192.168.1.50:8554/mic_raw \
  -s filtered=rtsp://192.168.1.50:8554/mic_filtered \
  -s bird=rtsp://192.168.1.50:8554/mic_bird \
  -d 60
```

### With BirdNET Detection Data

```bash
# Correlate audio quality with BirdNET detections
python3 lyrebird_stream_analyzer.py \
  -d 300 \
  -b /path/to/birdnet_detections.csv \
  -o analysis_with_detections.png
```

## Understanding the Output

### Text Report

The analyzer provides detailed statistics for each stream:

```
RAW Stream (28 chunks):
  RMS Level:              -42.3 dB
  Peak Level:             -18.7 dB
  Spectral Centroid:       3214 Hz
  
  Frequency Band Power:
    Low Freq (<1kHz):      -35.2 dB  ← Wind/vibration noise
    Mid Freq (1-3kHz):     -38.1 dB  ← Urban noise
    Bird Freq (3-8kHz):    -32.4 dB  ← Target signals
    High Freq (>8kHz):     -48.9 dB
  
  SNR Distribution (Bird/Low):
    Median:                  2.8 dB
    Std Dev:                 3.2 dB  ← Variability!
    25th percentile:         0.5 dB
    75th percentile:         5.1 dB
    Range:                  -2.3 to 8.9 dB
```

### Key Metrics Explained

- **Median SNR**: More reliable than mean for skewed distributions
- **Std Dev**: High values indicate inconsistent quality (e.g., wind gusts)
- **Percentiles**: Show distribution shape - tight clustering vs. wide spread
- **Range**: Identifies worst-case and best-case scenarios

### Visual Plots

The analyzer generates 7 plots showing:

1. **Full Spectrum** - Overall frequency response
2. **Bird Range Detail** - Focused view of 3-8kHz target range
3. **Band Power Comparison** - Bar chart of frequency band energy
4. **SNR Over Time** - Watch quality fluctuate with conditions
5. **SNR Histogram** - Distribution shape (normal, bimodal, skewed?)
6. **SNR Boxplot** - Quartiles and outliers at a glance
7. **Summary Stats** - Key numbers in tabular form

## Interpreting Results

### Good Filter Performance

```
RAW → FILTERED:
  Low Freq Reduction:      8.5 dB ✓ (removing noise)
  Bird Freq Change:       +0.2 dB ✓ (preserving signal)
  Median SNR Improvement: +8.3 dB ✓ (better quality)

FILTERED → BIRD:
  Low Freq Reduction:      4.2 dB ✓
  Bird Freq Change:       +1.1 dB ✓ (enhancing birds!)
  Median SNR Improvement: +5.3 dB ✓
```

### Red Flags

```
⚠️ Bird frequency being attenuated:
   Bird Freq Change: -3.5 dB (filter too aggressive!)

⚠️ High SNR variability:
   Std Dev: 8.7 dB (inconsistent conditions or poor isolation)

⚠️ Low SNR improvement:
   Median SNR Improvement: +1.2 dB (filters not effective)

⚠️ Spectral centroid too low:
   Spectral Centroid: 1200 Hz (dominated by low-freq noise)
```

## Integration with BirdNET-Go

This analyzer is designed to work alongside BirdNET-Go detection systems. Use it to:

1. **Optimize Filter Parameters** - Adjust your MediaMTX filters based on SNR distribution
2. **Validate Hardware Changes** - Test new microphones, capsules, or isolation improvements
3. **Monitor Environmental Conditions** - Understand when detection quality degrades
4. **Correlate Quality with Detections** - Compare SNR during high vs. low detection periods

### Example Workflow

```bash
# 1. Run 5-minute analysis during peak bird activity
python3 lyrebird_stream_analyzer.py -d 300 -o morning_analysis.png -j morning_data.json

# 2. Check if bird stream maintains >15 dB median SNR
# 3. Verify std dev is <5 dB (consistent quality)
# 4. Compare with BirdNET detection logs
# 5. Adjust filters if needed and re-test
```

## Configuration

### Default Streams

The analyzer expects these RTSP streams by default:

```python
'raw':      'rtsp://192.168.1.37:8554/rode_ai_micro_right_raw'
'filtered': 'rtsp://192.168.1.37:8554/rode_ai_micro_right_filt'
'bird':     'rtsp://192.168.1.37:8554/rode_ai_micro_right_bird'
```

### Frequency Bands

- **Low (<1kHz)**: Wind, handling noise, vibration
- **Mid (1-3kHz)**: Urban noise, traffic, machinery
- **Bird (3-8kHz)**: Most bird vocalizations - **target range**
- **High (>8kHz)**: Ultrasonic content, filter rolloff check

## Hardware Compatibility

Tested with:
- Rode AI Micro with AOM capsule
- MediaMTX streaming server
- BirdNET-Go detection system

Should work with any RTSP audio streams at 48kHz sample rate.

## Troubleshooting

### FFmpeg Connection Errors

```bash
# Test stream manually
ffplay rtsp://192.168.1.37:8554/rode_ai_micro_right_raw

# Check MediaMTX is running
ps aux | grep mediamtx

# Verify network connectivity
ping 192.168.1.37
```

### No Data Captured

- Ensure MediaMTX is publishing the streams
- Check RTSP URL is correct
- Verify firewall allows RTSP traffic (port 8554)
- Try TCP transport: already configured in analyzer

### Matplotlib Display Issues (macOS)

```bash
# Set backend
export MPLBACKEND=MacOSX

# Or use --no-plot and save directly
python3 lyrebird_stream_analyzer.py -d 30 --no-plot -j results.json
```

## Contributing

Contributions welcome! Areas of interest:

- Additional frequency analysis metrics
- BirdNET detection correlation algorithms
- Real-time streaming visualization
- Support for additional audio formats
- Machine learning quality prediction

## License

MIT License - see LICENSE file for details

## Acknowledgments

- Built for the LyreBird project
- Uses MediaMTX for RTSP streaming
- Integrates with BirdNET-Go for bird detection
- Inspired by the need for better signal quality metrics

## Related Projects

- [BirdNET-Go](https://github.com/tphakala/birdnet-go) - Bird sound identification
- [MediaMTX](https://github.com/bluenviron/mediamtx) - RTSP streaming server
- [LyreBird](https://github.com/yourusername/lyrebird) - Complete bird detection system

---

**Questions?** Open an issue or check existing discussions.

**Found a bug?** Please report it with sample output and your configuration.
