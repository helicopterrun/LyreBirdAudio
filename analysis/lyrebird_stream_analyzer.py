#!/usr/bin/env python3
"""
LyreBird Audio Stream Analyzer
==============================

Analyzes multiple RTSP audio streams to verify filtering performance and
optimize bird detection quality. Designed for use with BirdNET-Go and
MediaMTX streaming.

Streams analyzed:
- Raw: Unprocessed audio from microphone capsule
- Filtered: Basic noise reduction applied
- Bird: Optimized for bird frequency range (3-8kHz)

Features:
- Real-time frequency spectrum analysis
- SNR distribution tracking across time
- BirdNET detection quality correlation
- Comparative filter effectiveness metrics

Author: LyreBird Project
License: MIT
"""

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec
from scipy import signal
from scipy.fft import rfft, rfftfreq
import threading
import queue
import time
from datetime import datetime
import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Tuple, Optional

__version__ = "1.0.0"


class AudioStreamAnalyzer:
    """
    Analyzes RTSP audio streams for bird detection optimization.
    
    Captures and analyzes multiple audio streams simultaneously, computing
    frequency spectra, SNR distributions, and filter effectiveness metrics.
    """
    
    def __init__(
        self, 
        streams: Optional[Dict[str, str]] = None,
        sample_rate: int = 48000, 
        chunk_duration: float = 1.0,
        birdnet_detections: Optional[str] = None
    ):
        """
        Initialize the analyzer.
        
        Args:
            streams: Dict of stream names to RTSP URLs. If None, uses defaults.
            sample_rate: Audio sample rate in Hz (default: 48000)
            chunk_duration: Duration of each analysis chunk in seconds (default: 1.0)
            birdnet_detections: Path to BirdNET detection CSV file for correlation
        """
        self.sample_rate = sample_rate
        self.chunk_duration = chunk_duration
        self.chunk_size = int(sample_rate * chunk_duration)
        
        # RTSP stream URLs - can be overridden
        self.streams = streams or {
            'raw': 'rtsp://192.168.1.37:8554/rode_ai_micro_right_raw',
            'filtered': 'rtsp://192.168.1.37:8554/rode_ai_micro_right_filt',
            'bird': 'rtsp://192.168.1.37:8554/rode_ai_micro_right_bird'
        }
        
        # Data queues for each stream
        self.audio_queues = {name: queue.Queue(maxsize=10) for name in self.streams}
        self.running = False
        
        # Analysis results storage - now includes time series data
        self.results = {
            name: {
                'freq': None, 
                'psd': None, 
                'stats': {},
                'snr_history': [],  # SNR over time
                'timestamp_history': [],  # Timestamps for each chunk
                'bird_power_history': [],  # Bird band power over time
                'low_power_history': []  # Low freq power over time
            } 
            for name in self.streams
        }
        
        # BirdNET detection data (if provided)
        self.birdnet_data = None
        if birdnet_detections:
            self.load_birdnet_data(birdnet_detections)
    
    def load_birdnet_data(self, csv_path: str):
        """
        Load BirdNET detection results for correlation analysis.
        
        Args:
            csv_path: Path to BirdNET CSV output file
        """
        try:
            import pandas as pd
            self.birdnet_data = pd.read_csv(csv_path)
            print(f"Loaded {len(self.birdnet_data)} BirdNET detections from {csv_path}")
        except ImportError:
            print("WARNING: pandas not installed. Cannot load BirdNET data.")
            print("Install with: pip3 install pandas")
        except Exception as e:
            print(f"WARNING: Could not load BirdNET data: {e}")
    
    def capture_stream_ffmpeg(self, stream_name: str, url: str):
        """
        Capture audio from RTSP stream using FFmpeg subprocess.
        
        Args:
            stream_name: Name identifier for this stream
            url: RTSP URL to capture from
        """
        import subprocess
        
        print(f"Starting FFmpeg capture for {stream_name}: {url}")
        
        # FFmpeg command to capture audio and output as raw PCM
        cmd = [
            'ffmpeg',
            '-loglevel', 'error',
            '-rtsp_transport', 'tcp',
            '-i', url,
            '-f', 's16le',  # PCM signed 16-bit little-endian
            '-acodec', 'pcm_s16le',
            '-ar', str(self.sample_rate),
            '-ac', '1',  # Mono
            'pipe:1'
        ]
        
        try:
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=10**8
            )
            
            bytes_per_sample = 2  # 16-bit = 2 bytes
            chunk_bytes = self.chunk_size * bytes_per_sample
            
            while self.running:
                raw_audio = process.stdout.read(chunk_bytes)
                
                if len(raw_audio) == 0:
                    print(f"WARNING: No data from {stream_name}")
                    break
                
                if len(raw_audio) < chunk_bytes:
                    # Pad incomplete chunks
                    raw_audio += b'\x00' * (chunk_bytes - len(raw_audio))
                
                # Convert bytes to numpy array
                audio_data = np.frombuffer(raw_audio, dtype=np.int16)
                
                # Normalize to [-1, 1]
                audio_data = audio_data.astype(np.float32) / 32768.0
                
                # Add timestamp
                timestamp = time.time()
                
                # Add to queue if not full
                try:
                    self.audio_queues[stream_name].put_nowait((timestamp, audio_data))
                except queue.Full:
                    # Remove oldest and add new
                    try:
                        self.audio_queues[stream_name].get_nowait()
                        self.audio_queues[stream_name].put_nowait((timestamp, audio_data))
                    except:
                        pass
            
            process.terminate()
            process.wait()
            print(f"Stopped FFmpeg capture for {stream_name}")
            
        except Exception as e:
            print(f"ERROR in {stream_name} capture: {e}")
            import traceback
            traceback.print_exc()
    
    def analyze_frequency_spectrum(self, audio_data: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
        """
        Perform FFT analysis on audio data.
        
        Args:
            audio_data: Audio samples as numpy array
            
        Returns:
            Tuple of (frequencies, power_spectral_density_db)
        """
        # Apply window to reduce spectral leakage
        window = signal.windows.hann(len(audio_data))
        windowed_data = audio_data * window
        
        # Compute FFT
        fft_vals = rfft(windowed_data)
        fft_freq = rfftfreq(len(windowed_data), 1/self.sample_rate)
        
        # Compute power spectral density
        psd = np.abs(fft_vals) ** 2
        
        # Convert to dB
        psd_db = 10 * np.log10(psd + 1e-10)
        
        return fft_freq, psd_db
    
    def compute_statistics(
        self, 
        audio_data: np.ndarray, 
        freq: np.ndarray, 
        psd_db: np.ndarray
    ) -> Dict[str, float]:
        """
        Compute audio statistics and band power analysis.
        
        Args:
            audio_data: Audio samples
            freq: Frequency bins from FFT
            psd_db: Power spectral density in dB
            
        Returns:
            Dictionary of computed statistics
        """
        stats = {}
        
        # RMS level
        stats['rms'] = np.sqrt(np.mean(audio_data ** 2))
        stats['rms_db'] = 20 * np.log10(stats['rms'] + 1e-10)
        
        # Peak level
        stats['peak'] = np.max(np.abs(audio_data))
        stats['peak_db'] = 20 * np.log10(stats['peak'] + 1e-10)
        
        # Crest factor (peak to RMS ratio)
        stats['crest_factor'] = stats['peak'] / (stats['rms'] + 1e-10)
        stats['crest_factor_db'] = 20 * np.log10(stats['crest_factor'])
        
        # Frequency band analysis
        # Low frequency (< 1kHz) - wind/handling/vibration noise
        low_mask = freq < 1000
        stats['low_freq_power'] = np.mean(psd_db[low_mask]) if np.any(low_mask) else -np.inf
        
        # Mid frequency (1-3kHz) - urban noise, traffic
        mid_mask = (freq >= 1000) & (freq < 3000)
        stats['mid_freq_power'] = np.mean(psd_db[mid_mask]) if np.any(mid_mask) else -np.inf
        
        # Bird frequency (3-8kHz) - primary target range for most bird species
        bird_mask = (freq >= 3000) & (freq <= 8000)
        stats['bird_freq_power'] = np.mean(psd_db[bird_mask]) if np.any(bird_mask) else -np.inf
        
        # High frequency (> 8kHz) - ultrasonic, filter rolloff check
        high_mask = freq > 8000
        stats['high_freq_power'] = np.mean(psd_db[high_mask]) if np.any(high_mask) else -np.inf
        
        # Signal to noise ratios
        stats['snr_bird_to_low'] = stats['bird_freq_power'] - stats['low_freq_power']
        stats['snr_bird_to_mid'] = stats['bird_freq_power'] - stats['mid_freq_power']
        
        # Spectral centroid (center of mass of spectrum)
        stats['spectral_centroid'] = np.sum(freq * psd_db) / np.sum(psd_db)
        
        # Spectral rolloff (frequency below which 85% of energy is contained)
        cumsum = np.cumsum(psd_db)
        rolloff_idx = np.where(cumsum >= 0.85 * cumsum[-1])[0]
        stats['spectral_rolloff'] = freq[rolloff_idx[0]] if len(rolloff_idx) > 0 else 0
        
        return stats
    
    def analyze_streams(self, duration: int = 10):
        """
        Analyze all streams for a given duration.
        
        Args:
            duration: Analysis duration in seconds
        """
        print(f"\nAnalyzing streams for {duration} seconds...")
        print("Press Ctrl+C to stop early\n")
        
        # Start capture threads
        self.running = True
        threads = []
        
        for name, url in self.streams.items():
            t = threading.Thread(target=self.capture_stream_ffmpeg, args=(name, url))
            t.daemon = True
            t.start()
            threads.append(t)
        
        # Wait for initial data
        print("Waiting for stream data...")
        time.sleep(2)
        
        # Collect and analyze data
        start_time = time.time()
        analysis_count = {name: 0 for name in self.streams}
        last_print = start_time
        
        while time.time() - start_time < duration:
            current_time = time.time()
            
            # Progress indicator every 5 seconds
            if current_time - last_print >= 5:
                elapsed = current_time - start_time
                remaining = duration - elapsed
                print(f"  Progress: {elapsed:.0f}s / {duration}s ({remaining:.0f}s remaining)")
                last_print = current_time
            
            for name in self.streams:
                try:
                    timestamp, audio_data = self.audio_queues[name].get(timeout=0.5)
                    
                    # Analyze frequency spectrum
                    freq, psd_db = self.analyze_frequency_spectrum(audio_data)
                    
                    # Compute statistics
                    stats = self.compute_statistics(audio_data, freq, psd_db)
                    
                    # Store latest results
                    self.results[name]['freq'] = freq
                    self.results[name]['psd'] = psd_db
                    self.results[name]['stats'] = stats
                    
                    # Store time series data for distribution analysis
                    self.results[name]['snr_history'].append(stats['snr_bird_to_low'])
                    self.results[name]['timestamp_history'].append(timestamp)
                    self.results[name]['bird_power_history'].append(stats['bird_freq_power'])
                    self.results[name]['low_power_history'].append(stats['low_freq_power'])
                    
                    analysis_count[name] += 1
                    
                except queue.Empty:
                    continue
            
            time.sleep(0.05)  # Small sleep to prevent busy loop
        
        # Stop capture
        self.running = False
        for t in threads:
            t.join(timeout=2)
        
        total_chunks = sum(analysis_count.values())
        print(f"\nAnalysis complete!")
        print(f"Total chunks processed: {total_chunks}")
        for name, count in analysis_count.items():
            print(f"  {name}: {count} chunks")
    
    def print_comparison(self):
        """Print detailed comparison of the three streams."""
        print("\n" + "="*80)
        print("LYREBIRD AUDIO STREAM ANALYSIS RESULTS")
        print("="*80)
        
        for name in self.streams.keys():
            stats = self.results[name]['stats']
            snr_history = self.results[name]['snr_history']
            
            if not stats:
                print(f"\n{name.upper()}: No data available")
                continue
            
            # Calculate distribution statistics
            snr_array = np.array(snr_history)
            snr_median = np.median(snr_array)
            snr_std = np.std(snr_array)
            snr_p25 = np.percentile(snr_array, 25)
            snr_p75 = np.percentile(snr_array, 75)
            snr_min = np.min(snr_array)
            snr_max = np.max(snr_array)
                
            print(f"\n{name.upper()} Stream ({len(snr_history)} chunks):")
            print(f"  RMS Level:           {stats['rms_db']:>7.1f} dB")
            print(f"  Peak Level:          {stats['peak_db']:>7.1f} dB")
            print(f"  Crest Factor:        {stats['crest_factor_db']:>7.1f} dB")
            print(f"  Spectral Centroid:   {stats['spectral_centroid']:>7.0f} Hz")
            print(f"  Spectral Rolloff:    {stats['spectral_rolloff']:>7.0f} Hz")
            print(f"\n  Frequency Band Power:")
            print(f"    Low Freq (<1kHz):    {stats['low_freq_power']:>7.1f} dB")
            print(f"    Mid Freq (1-3kHz):   {stats['mid_freq_power']:>7.1f} dB")
            print(f"    Bird Freq (3-8kHz):  {stats['bird_freq_power']:>7.1f} dB")
            print(f"    High Freq (>8kHz):   {stats['high_freq_power']:>7.1f} dB")
            print(f"\n  SNR Distribution (Bird/Low):")
            print(f"    Median:              {snr_median:>7.1f} dB")
            print(f"    Mean:                {np.mean(snr_array):>7.1f} dB")
            print(f"    Std Dev:             {snr_std:>7.1f} dB")
            print(f"    25th percentile:     {snr_p25:>7.1f} dB")
            print(f"    75th percentile:     {snr_p75:>7.1f} dB")
            print(f"    Range:               {snr_min:>7.1f} to {snr_max:.1f} dB")
        
        # Print comparisons
        print("\n" + "-"*80)
        print("FILTER EFFECTIVENESS:")
        print("-"*80)
        
        stream_names = list(self.streams.keys())
        
        # Compare consecutive streams
        for i in range(len(stream_names) - 1):
            curr_name = stream_names[i]
            next_name = stream_names[i + 1]
            
            if self.results[curr_name]['stats'] and self.results[next_name]['stats']:
                curr_stats = self.results[curr_name]['stats']
                next_stats = self.results[next_name]['stats']
                
                curr_snr = np.array(self.results[curr_name]['snr_history'])
                next_snr = np.array(self.results[next_name]['snr_history'])
                
                low_reduction = curr_stats['low_freq_power'] - next_stats['low_freq_power']
                bird_change = next_stats['bird_freq_power'] - curr_stats['bird_freq_power']
                median_snr_improvement = np.median(next_snr) - np.median(curr_snr)
                
                print(f"\n  {curr_name.upper()} → {next_name.upper()}:")
                print(f"    Low Freq Reduction:       {low_reduction:>7.1f} dB")
                print(f"    Bird Freq Change:         {bird_change:>+7.1f} dB")
                print(f"    Median SNR Improvement:   {median_snr_improvement:>+7.1f} dB")
        
        print("\n" + "="*80)
    
    def plot_comparison(self, save_path: Optional[str] = None):
        """
        Create comprehensive comparison plots including SNR distributions.
        
        Args:
            save_path: Optional path to save the plot image
        """
        # Create figure with custom grid layout
        fig = plt.figure(figsize=(18, 12), constrained_layout=True)
        gs = GridSpec(3, 3, figure=fig)
        
        fig.suptitle('LyreBird Audio Stream Analysis', fontsize=16, fontweight='bold')
        
        colors = {name: color for name, color in zip(
            self.streams.keys(),
            ['#2E86AB', '#A23B72', '#F18F01']  # Blue, Purple, Orange
        )}
        
        # Plot 1: Full spectrum comparison (top left)
        ax1 = fig.add_subplot(gs[0, 0])
        for name in self.streams.keys():
            if self.results[name]['freq'] is not None:
                freq = self.results[name]['freq']
                psd = self.results[name]['psd']
                ax1.plot(freq, psd, label=name.capitalize(), color=colors[name], alpha=0.7, linewidth=1.5)
        
        ax1.set_xlabel('Frequency (Hz)')
        ax1.set_ylabel('Power (dB)')
        ax1.set_title('Full Frequency Spectrum')
        ax1.set_xlim([0, self.sample_rate/2])
        ax1.grid(True, alpha=0.3)
        ax1.legend()
        
        # Plot 2: Bird frequency range detail (top middle)
        ax2 = fig.add_subplot(gs[0, 1])
        for name in self.streams.keys():
            if self.results[name]['freq'] is not None:
                freq = self.results[name]['freq']
                psd = self.results[name]['psd']
                mask = (freq >= 3000) & (freq <= 8000)
                ax2.plot(freq[mask], psd[mask], label=name.capitalize(), 
                        color=colors[name], alpha=0.7, linewidth=2)
        
        ax2.set_xlabel('Frequency (Hz)')
        ax2.set_ylabel('Power (dB)')
        ax2.set_title('Bird Frequency Range (3-8 kHz)')
        ax2.grid(True, alpha=0.3)
        ax2.legend()
        
        # Plot 3: Frequency band power comparison (top right)
        ax3 = fig.add_subplot(gs[0, 2])
        bands = ['Low\n(<1kHz)', 'Mid\n(1-3kHz)', 'Bird\n(3-8kHz)', 'High\n(>8kHz)']
        x = np.arange(len(bands))
        width = 0.25
        
        for i, name in enumerate(self.streams.keys()):
            if self.results[name]['stats']:
                stats = self.results[name]['stats']
                powers = [
                    stats['low_freq_power'],
                    stats['mid_freq_power'],
                    stats['bird_freq_power'],
                    stats['high_freq_power']
                ]
                offset = (i - len(self.streams)/2 + 0.5) * width
                ax3.bar(x + offset, powers, width, label=name.capitalize(), 
                       color=colors[name], alpha=0.7)
        
        ax3.set_xlabel('Frequency Band')
        ax3.set_ylabel('Average Power (dB)')
        ax3.set_title('Power Distribution by Band')
        ax3.set_xticks(x)
        ax3.set_xticklabels(bands)
        ax3.legend()
        ax3.grid(True, alpha=0.3, axis='y')
        
        # Plot 4: SNR over time (middle row, spans all columns)
        ax4 = fig.add_subplot(gs[1, :])
        for name in self.streams.keys():
            if self.results[name]['snr_history']:
                timestamps = self.results[name]['timestamp_history']
                snr_history = self.results[name]['snr_history']
                # Convert to relative time
                rel_times = np.array(timestamps) - timestamps[0]
                ax4.plot(rel_times, snr_history, label=name.capitalize(), 
                        color=colors[name], alpha=0.6, linewidth=1.5)
                # Add median line
                median_snr = np.median(snr_history)
                ax4.axhline(median_snr, color=colors[name], linestyle='--', 
                           alpha=0.4, linewidth=1)
        
        ax4.set_xlabel('Time (seconds)')
        ax4.set_ylabel('SNR (dB)')
        ax4.set_title('Signal-to-Noise Ratio Over Time (Bird/Low Frequency)')
        ax4.grid(True, alpha=0.3)
        ax4.legend()
        
        # Plot 5: SNR Distribution - Histogram (bottom left)
        ax5 = fig.add_subplot(gs[2, 0])
        snr_data = []
        labels = []
        for name in self.streams.keys():
            if self.results[name]['snr_history']:
                snr_data.append(self.results[name]['snr_history'])
                labels.append(name.capitalize())
        
        ax5.hist(snr_data, bins=30, label=labels, alpha=0.6, 
                color=[colors[name] for name in self.streams.keys()])
        ax5.set_xlabel('SNR (dB)')
        ax5.set_ylabel('Count')
        ax5.set_title('SNR Distribution (Histogram)')
        ax5.legend()
        ax5.grid(True, alpha=0.3, axis='y')
        
        # Plot 6: SNR Distribution - Box Plot (bottom middle)
        ax6 = fig.add_subplot(gs[2, 1])
        snr_data = []
        positions = []
        box_colors = []
        
        for i, name in enumerate(self.streams.keys()):
            if self.results[name]['snr_history']:
                snr_data.append(self.results[name]['snr_history'])
                positions.append(i)
                box_colors.append(colors[name])
        
        bp = ax6.boxplot(snr_data, positions=positions, widths=0.6, patch_artist=True,
                        tick_labels=[name.capitalize() for name in self.streams.keys()])
        
        for patch, color in zip(bp['boxes'], box_colors):
            patch.set_facecolor(color)
            patch.set_alpha(0.6)
        
        ax6.set_ylabel('SNR (dB)')
        ax6.set_title('SNR Distribution (Boxplot)')
        ax6.grid(True, alpha=0.3, axis='y')
        
        # Plot 7: Summary statistics (bottom right)
        ax7 = fig.add_subplot(gs[2, 2])
        ax7.axis('off')
        
        # Create summary table
        summary_text = "Summary Statistics\n" + "="*30 + "\n\n"
        
        for name in self.streams.keys():
            if self.results[name]['snr_history']:
                snr_array = np.array(self.results[name]['snr_history'])
                summary_text += f"{name.upper()}:\n"
                summary_text += f"  Median SNR: {np.median(snr_array):.1f} dB\n"
                summary_text += f"  Std Dev:    {np.std(snr_array):.1f} dB\n"
                summary_text += f"  Range:      {np.min(snr_array):.1f} to {np.max(snr_array):.1f} dB\n"
                summary_text += f"  Chunks:     {len(snr_array)}\n\n"
        
        ax7.text(0.1, 0.95, summary_text, transform=ax7.transAxes,
                fontsize=10, verticalalignment='top', fontfamily='monospace',
                bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.3))
        
        if save_path:
            plt.savefig(save_path, dpi=300, bbox_inches='tight')
            print(f"\nPlot saved to: {save_path}")
        
        plt.show()
    
    def export_results(self, output_path: str):
        """
        Export analysis results to JSON file.
        
        Args:
            output_path: Path to save JSON results
        """
        export_data = {
            'metadata': {
                'version': __version__,
                'timestamp': datetime.now().isoformat(),
                'sample_rate': self.sample_rate,
                'chunk_duration': self.chunk_duration
            },
            'streams': {}
        }
        
        for name in self.streams.keys():
            if self.results[name]['stats']:
                export_data['streams'][name] = {
                    'stats': self.results[name]['stats'],
                    'snr_history': self.results[name]['snr_history'],
                    'snr_median': float(np.median(self.results[name]['snr_history'])),
                    'snr_std': float(np.std(self.results[name]['snr_history'])),
                    'chunk_count': len(self.results[name]['snr_history'])
                }
        
        with open(output_path, 'w') as f:
            json.dump(export_data, f, indent=2)
        
        print(f"\nResults exported to: {output_path}")


def main():
    """Main entry point for the analyzer."""
    parser = argparse.ArgumentParser(
        description='Analyze LyreBird audio streams for bird detection optimization',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic 30-second analysis
  %(prog)s -d 30
  
  # Analysis with saved plot and JSON export
  %(prog)s -d 60 -o analysis.png -j results.json
  
  # Custom stream URLs
  %(prog)s -d 30 -s raw=rtsp://192.168.1.50:8554/raw \\
                    -s filtered=rtsp://192.168.1.50:8554/filt
  
  # With BirdNET detection correlation
  %(prog)s -d 300 -b birdnet_detections.csv -o analysis.png

For more information, visit: https://github.com/yourusername/lyrebird
        """
    )
    
    parser.add_argument(
        '-d', '--duration', 
        type=int, 
        default=10,
        help='Analysis duration in seconds (default: 10)'
    )
    
    parser.add_argument(
        '-o', '--output', 
        type=str, 
        default=None,
        help='Output file path for plot (PNG format)'
    )
    
    parser.add_argument(
        '-j', '--json',
        type=str,
        default=None,
        help='Export results to JSON file'
    )
    
    parser.add_argument(
        '--no-plot', 
        action='store_true',
        help='Skip plotting and only show text analysis'
    )
    
    parser.add_argument(
        '-s', '--stream',
        action='append',
        help='Override stream URL (format: name=url). Can be specified multiple times.'
    )
    
    parser.add_argument(
        '-b', '--birdnet',
        type=str,
        default=None,
        help='Path to BirdNET detection CSV for correlation analysis'
    )
    
    parser.add_argument(
        '-v', '--version',
        action='version',
        version=f'%(prog)s {__version__}'
    )
    
    args = parser.parse_args()
    
    # Parse custom streams if provided
    custom_streams = None
    if args.stream:
        custom_streams = {}
        for stream_spec in args.stream:
            try:
                name, url = stream_spec.split('=', 1)
                custom_streams[name] = url
            except ValueError:
                print(f"ERROR: Invalid stream specification: {stream_spec}")
                print("Format should be: name=url")
                sys.exit(1)
    
    # Print banner
    print("="*80)
    print("LyreBird Audio Stream Analyzer v" + __version__)
    print("="*80)
    print("\nThis script analyzes audio streams for bird detection optimization.")
    
    if custom_streams:
        print(f"\nAnalyzing {len(custom_streams)} custom streams:")
        for name, url in custom_streams.items():
            print(f"  • {name}: {url}")
    else:
        print("\nAnalyzing default streams:")
        print("  • Raw - Unprocessed audio from microphone")
        print("  • Filtered - Basic noise reduction")
        print("  • Bird - Optimized for bird frequency range (3-8kHz)")
    
    print("\nMake sure MediaMTX is running and streams are available!")
    print("="*80)
    
    # Create analyzer
    analyzer = AudioStreamAnalyzer(
        streams=custom_streams,
        sample_rate=48000, 
        chunk_duration=1.0,
        birdnet_detections=args.birdnet
    )
    
    try:
        # Run analysis
        analyzer.analyze_streams(duration=args.duration)
        
        # Print results
        analyzer.print_comparison()
        
        # Export JSON if requested
        if args.json:
            analyzer.export_results(args.json)
        
        # Plot if requested
        if not args.no_plot:
            analyzer.plot_comparison(save_path=args.output)
            
    except KeyboardInterrupt:
        print("\n\nAnalysis interrupted by user")
        analyzer.running = False
    except Exception as e:
        print(f"\nERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
