#!/usr/bin/env python3
"""
LyreBird Detection Quality Correlator
=====================================

Combines BirdNET-Go detection data with real-time audio stream analysis
to understand the relationship between audio quality (SNR) and detection
confidence/success rate.

This tool answers questions like:
- What SNR do we need for reliable detections?
- Which species need better SNR?
- How does filter choice affect detection confidence?
- When does audio quality degrade (and why)?

Author: LyreBird Project
License: MIT
"""

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec
import argparse
import json
import requests
from datetime import datetime, timedelta
from typing import List, Dict, Optional, Tuple
from pathlib import Path
import sys

__version__ = "1.0.0"


def fetch_recent_detections(birdnet_url: str, hours: int = 1) -> List[Dict]:
    """
    Fetch recent detections from BirdNET-Go API.
    
    Args:
        birdnet_url: BirdNET-Go server URL
        hours: How many hours back to fetch
        
    Returns:
        List of detection dictionaries
    """
    print(f"Fetching detections from last {hours} hour(s)...")
    
    date_from = (datetime.now() - timedelta(hours=hours)).strftime('%Y-%m-%d')
    
    try:
        response = requests.get(
            f"{birdnet_url}/api/detections",
            params={
                'limit': 10000,
                'dateFrom': date_from
            },
            timeout=10
        )
        response.raise_for_status()
        detections = response.json()
        print(f"Found {len(detections)} detections")
        return detections
    except Exception as e:
        print(f"ERROR fetching detections: {e}")
        return []


def analyze_detection_clips(
    detections: List[Dict],
    clips_dir: str
) -> Dict[str, Dict]:
    """
    Analyze audio clips from detections.
    
    Args:
        detections: List of detection dictionaries
        clips_dir: Directory containing audio clips
        
    Returns:
        Dictionary mapping clip names to analysis results
    """
    from scipy.io import wavfile
    from scipy import signal as scipy_signal
    from scipy.fft import rfft, rfftfreq
    
    results = {}
    clips_path = Path(clips_dir)
    
    print(f"\nAnalyzing audio clips from {clips_dir}...")
    
    for i, det in enumerate(detections):
        clip_name = det.get('clipName')
        if not clip_name:
            continue
        
        clip_path = clips_path / clip_name
        if not clip_path.exists():
            continue
        
        try:
            # Load audio clip
            sample_rate, audio_data = wavfile.read(str(clip_path))
            
            # Convert to mono if stereo
            if len(audio_data.shape) > 1:
                audio_data = audio_data.mean(axis=1)
            
            # Normalize
            audio_data = audio_data.astype(np.float32) / 32768.0
            
            # Apply window
            window = scipy_signal.windows.hann(len(audio_data))
            windowed = audio_data * window
            
            # FFT
            fft_vals = rfft(windowed)
            fft_freq = rfftfreq(len(windowed), 1/sample_rate)
            psd = np.abs(fft_vals) ** 2
            psd_db = 10 * np.log10(psd + 1e-10)
            
            # Analyze frequency bands
            low_mask = fft_freq < 1000
            bird_mask = (fft_freq >= 3000) & (fft_freq <= 8000)
            
            low_power = np.mean(psd_db[low_mask]) if np.any(low_mask) else -np.inf
            bird_power = np.mean(psd_db[bird_mask]) if np.any(bird_mask) else -np.inf
            snr = bird_power - low_power
            
            results[clip_name] = {
                'snr': snr,
                'bird_power': bird_power,
                'low_power': low_power,
                'rms': np.sqrt(np.mean(audio_data ** 2)),
                'peak': np.max(np.abs(audio_data)),
                'species': det.get('commonName', 'Unknown'),
                'confidence': det.get('confidence', 0),
                'timestamp': det.get('timestamp', '')
            }
            
            if (i + 1) % 10 == 0:
                print(f"  Processed {i + 1}/{len(detections)} clips...", end='\r')
        
        except Exception as e:
            print(f"  Error processing {clip_name}: {e}")
            continue
    
    print(f"\nSuccessfully analyzed {len(results)} clips")
    return results


def correlate_quality_and_confidence(
    analysis_results: Dict[str, Dict]
) -> Dict:
    """
    Analyze correlation between audio quality and detection confidence.
    
    Args:
        analysis_results: Dictionary of clip analysis results
        
    Returns:
        Correlation statistics
    """
    if not analysis_results:
        return {}
    
    snrs = []
    confidences = []
    species_data = {}
    
    for clip_name, data in analysis_results.items():
        snr = data['snr']
        conf = data['confidence']
        species = data['species']
        
        if np.isfinite(snr) and conf > 0:
            snrs.append(snr)
            confidences.append(conf)
            
            if species not in species_data:
                species_data[species] = {'snrs': [], 'confidences': []}
            species_data[species]['snrs'].append(snr)
            species_data[species]['confidences'].append(conf)
    
    if not snrs:
        return {}
    
    # Overall correlation
    correlation = np.corrcoef(snrs, confidences)[0, 1]
    
    # Bin SNR and calculate average confidence per bin
    snr_bins = np.arange(0, 60, 5)  # 0-5, 5-10, ..., 55-60 dB
    conf_by_snr = []
    
    for i in range(len(snr_bins) - 1):
        mask = (np.array(snrs) >= snr_bins[i]) & (np.array(snrs) < snr_bins[i+1])
        if np.any(mask):
            conf_by_snr.append({
                'snr_range': (snr_bins[i], snr_bins[i+1]),
                'avg_confidence': np.mean(np.array(confidences)[mask]),
                'count': np.sum(mask)
            })
    
    # Per-species analysis
    species_stats = {}
    for species, data in species_data.items():
        if len(data['snrs']) >= 3:  # Only species with 3+ detections
            species_stats[species] = {
                'avg_snr': np.mean(data['snrs']),
                'avg_confidence': np.mean(data['confidences']),
                'snr_std': np.std(data['snrs']),
                'count': len(data['snrs'])
            }
    
    return {
        'correlation': correlation,
        'total_samples': len(snrs),
        'snr_range': (np.min(snrs), np.max(snrs)),
        'confidence_by_snr': conf_by_snr,
        'species_stats': species_stats
    }


def plot_quality_correlation(
    analysis_results: Dict[str, Dict],
    correlation_stats: Dict,
    save_path: Optional[str] = None
):
    """
    Create visualization of quality vs confidence correlation.
    
    Args:
        analysis_results: Dictionary of clip analysis results
        correlation_stats: Correlation statistics
        save_path: Optional path to save plot
    """
    fig = plt.figure(figsize=(16, 10), constrained_layout=True)
    gs = GridSpec(2, 3, figure=fig)
    
    fig.suptitle('BirdNET Detection Quality Analysis', fontsize=16, fontweight='bold')
    
    # Extract data
    snrs = []
    confidences = []
    species_list = []
    
    for data in analysis_results.values():
        if np.isfinite(data['snr']):
            snrs.append(data['snr'])
            confidences.append(data['confidence'])
            species_list.append(data['species'])
    
    snrs = np.array(snrs)
    confidences = np.array(confidences)
    
    # Plot 1: Scatter plot SNR vs Confidence
    ax1 = fig.add_subplot(gs[0, 0])
    scatter = ax1.scatter(snrs, confidences, alpha=0.5, s=30, c=confidences, cmap='viridis')
    
    # Add trend line
    z = np.polyfit(snrs, confidences, 1)
    p = np.poly1d(z)
    x_trend = np.linspace(snrs.min(), snrs.max(), 100)
    ax1.plot(x_trend, p(x_trend), "r--", alpha=0.8, linewidth=2)
    
    ax1.set_xlabel('SNR (dB)')
    ax1.set_ylabel('Detection Confidence')
    ax1.set_title(f'SNR vs Confidence\n(correlation: {correlation_stats["correlation"]:.3f})')
    ax1.grid(True, alpha=0.3)
    plt.colorbar(scatter, ax=ax1, label='Confidence')
    
    # Plot 2: Confidence by SNR bins
    ax2 = fig.add_subplot(gs[0, 1])
    if 'confidence_by_snr' in correlation_stats:
        bins_data = correlation_stats['confidence_by_snr']
        bin_centers = [(b['snr_range'][0] + b['snr_range'][1]) / 2 for b in bins_data]
        avg_confs = [b['avg_confidence'] for b in bins_data]
        counts = [b['count'] for b in bins_data]
        
        bars = ax2.bar(bin_centers, avg_confs, width=4, alpha=0.7, color='steelblue')
        
        # Add count labels
        for bar, count in zip(bars, counts):
            height = bar.get_height()
            ax2.text(bar.get_x() + bar.get_width()/2., height,
                    f'n={count}', ha='center', va='bottom', fontsize=8)
        
        ax2.set_xlabel('SNR Range (dB)')
        ax2.set_ylabel('Average Confidence')
        ax2.set_title('Confidence by SNR Range')
        ax2.grid(True, alpha=0.3, axis='y')
    
    # Plot 3: SNR distribution
    ax3 = fig.add_subplot(gs[0, 2])
    ax3.hist(snrs, bins=30, color='steelblue', alpha=0.7, edgecolor='black')
    ax3.axvline(np.median(snrs), color='red', linestyle='--', linewidth=2, label=f'Median: {np.median(snrs):.1f} dB')
    ax3.set_xlabel('SNR (dB)')
    ax3.set_ylabel('Count')
    ax3.set_title('SNR Distribution Across Detections')
    ax3.legend()
    ax3.grid(True, alpha=0.3, axis='y')
    
    # Plot 4: Top species by average SNR
    ax4 = fig.add_subplot(gs[1, :2])
    if 'species_stats' in correlation_stats:
        species_stats = correlation_stats['species_stats']
        # Sort by count, take top 15
        top_species = sorted(species_stats.items(), key=lambda x: x[1]['count'], reverse=True)[:15]
        
        species_names = [s[0] for s in top_species]
        avg_snrs = [s[1]['avg_snr'] for s in top_species]
        avg_confs = [s[1]['avg_confidence'] for s in top_species]
        counts = [s[1]['count'] for s in top_species]
        
        y_pos = np.arange(len(species_names))
        
        # Create bars colored by confidence
        bars = ax4.barh(y_pos, avg_snrs, color=plt.cm.viridis(np.array(avg_confs)))
        
        # Add count labels
        for i, (bar, count) in enumerate(zip(bars, counts)):
            width = bar.get_width()
            ax4.text(width, bar.get_y() + bar.get_height()/2.,
                    f' {count}×', ha='left', va='center', fontsize=8)
        
        ax4.set_yticks(y_pos)
        ax4.set_yticklabels(species_names, fontsize=9)
        ax4.set_xlabel('Average SNR (dB)')
        ax4.set_title('Top Species by Detection Count (colored by avg confidence)')
        ax4.grid(True, alpha=0.3, axis='x')
    
    # Plot 5: Summary statistics
    ax5 = fig.add_subplot(gs[1, 2])
    ax5.axis('off')
    
    summary_text = "Summary Statistics\n" + "="*30 + "\n\n"
    summary_text += f"Total Detections: {len(snrs)}\n\n"
    summary_text += f"SNR Statistics:\n"
    summary_text += f"  Mean:   {np.mean(snrs):6.1f} dB\n"
    summary_text += f"  Median: {np.median(snrs):6.1f} dB\n"
    summary_text += f"  Std:    {np.std(snrs):6.1f} dB\n"
    summary_text += f"  Range:  {np.min(snrs):6.1f} to {np.max(snrs):.1f} dB\n\n"
    summary_text += f"Confidence Statistics:\n"
    summary_text += f"  Mean:   {np.mean(confidences):6.3f}\n"
    summary_text += f"  Median: {np.median(confidences):6.3f}\n"
    summary_text += f"  Std:    {np.std(confidences):6.3f}\n\n"
    summary_text += f"Correlation:\n"
    summary_text += f"  r = {correlation_stats['correlation']:.3f}\n"
    
    ax5.text(0.1, 0.95, summary_text, transform=ax5.transAxes,
            fontsize=10, verticalalignment='top', fontfamily='monospace',
            bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.3))
    
    if save_path:
        plt.savefig(save_path, dpi=300, bbox_inches='tight')
        print(f"\nPlot saved to: {save_path}")
    
    plt.show()


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Analyze correlation between audio quality and BirdNET detections',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Analyze last hour of detections
  %(prog)s --url http://192.168.1.37:8080 --clips /path/to/clips

  # Analyze last 6 hours with plot
  %(prog)s --url http://192.168.1.37:8080 --clips /path/to/clips \\
           --hours 6 --output correlation.png
  
  # Export results to JSON
  %(prog)s --url http://192.168.1.37:8080 --clips /path/to/clips \\
           --json results.json

This tool helps answer:
- What SNR do I need for reliable detections?
- Which species need better audio quality?
- How does my filter affect detection confidence?
        """
    )
    
    parser.add_argument(
        '--url',
        type=str,
        required=True,
        help='BirdNET-Go server URL (e.g., http://192.168.1.37:8080)'
    )
    
    parser.add_argument(
        '--clips',
        type=str,
        required=True,
        help='Path to directory containing audio clips'
    )
    
    parser.add_argument(
        '--hours',
        type=int,
        default=1,
        help='Analyze detections from last N hours (default: 1)'
    )
    
    parser.add_argument(
        '--output', '-o',
        type=str,
        help='Save plot to file'
    )
    
    parser.add_argument(
        '--json', '-j',
        type=str,
        help='Export analysis results to JSON'
    )
    
    parser.add_argument(
        '-v', '--version',
        action='version',
        version=f'%(prog)s {__version__}'
    )
    
    args = parser.parse_args()
    
    # Print banner
    print("="*80)
    print("LyreBird Detection Quality Correlator v" + __version__)
    print("="*80)
    print()
    
    # Fetch detections
    detections = fetch_recent_detections(args.url, args.hours)
    
    if not detections:
        print("No detections found")
        sys.exit(1)
    
    # Analyze audio clips
    analysis_results = analyze_detection_clips(detections, args.clips)
    
    if not analysis_results:
        print("\nERROR: No audio clips could be analyzed")
        print(f"Please check that clips exist in: {args.clips}")
        sys.exit(1)
    
    # Compute correlations
    correlation_stats = correlate_quality_and_confidence(analysis_results)
    
    if not correlation_stats:
        print("\nERROR: Could not compute correlations")
        sys.exit(1)
    
    # Print results
    print("\n" + "="*80)
    print("DETECTION QUALITY CORRELATION ANALYSIS")
    print("="*80)
    print(f"\nTotal detections analyzed: {correlation_stats['total_samples']}")
    print(f"SNR range: {correlation_stats['snr_range'][0]:.1f} to {correlation_stats['snr_range'][1]:.1f} dB")
    print(f"Correlation (SNR vs Confidence): {correlation_stats['correlation']:.3f}")
    
    if abs(correlation_stats['correlation']) > 0.5:
        print("  ✓ Strong correlation - audio quality significantly affects detection confidence")
    elif abs(correlation_stats['correlation']) > 0.3:
        print("  ✓ Moderate correlation - audio quality impacts detection confidence")
    else:
        print("  ⚠ Weak correlation - other factors may be more important")
    
    # Export JSON if requested
    if args.json:
        export_data = {
            'metadata': {
                'version': __version__,
                'timestamp': datetime.now().isoformat(),
                'hours_analyzed': args.hours,
                'clips_directory': args.clips
            },
            'correlation_stats': correlation_stats,
            'clip_analysis': analysis_results
        }
        
        with open(args.json, 'w') as f:
            json.dump(export_data, f, indent=2)
        
        print(f"\nResults exported to: {args.json}")
    
    # Plot
    plot_quality_correlation(analysis_results, correlation_stats, save_path=args.output)


if __name__ == "__main__":
    main()
