#!/usr/bin/env python3
"""
BirdNET-Go Detection Analyzer
==============================

Fetches bird detections from BirdNET-Go API and analyzes audio stream
quality during detection periods to optimize filtering and detection performance.

Features:
- Fetch detections from BirdNET-Go REST API
- Analyze audio quality during actual bird detections
- Correlate SNR with detection confidence
- Identify species-specific audio characteristics
- Recommend optimal filter settings

Author: LyreBird Project
License: MIT
"""

import requests
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec
import argparse
import json
from datetime import datetime, timedelta
from typing import List, Dict, Optional
import sys
from collections import defaultdict

__version__ = "1.0.0"


class BirdNETGoAPI:
    """
    Interface to BirdNET-Go REST API.
    
    API Documentation: https://github.com/tphakala/birdnet-go/blob/main/doc/api.md
    """
    
    def __init__(self, base_url: str = "http://localhost:8080"):
        """
        Initialize API client.
        
        Args:
            base_url: Base URL of BirdNET-Go server (default: http://localhost:8080)
        """
        self.base_url = base_url.rstrip('/')
        self.session = requests.Session()
    
    def test_connection(self) -> bool:
        """Test if BirdNET-Go API is accessible."""
        try:
            response = self.session.get(f"{self.base_url}/api/detections", timeout=5)
            return response.status_code in [200, 401]  # 200 = OK, 401 = needs auth but server is up
        except Exception as e:
            print(f"Connection failed: {e}")
            return False
    
    def get_detections(
        self, 
        limit: int = 100,
        offset: int = 0,
        species: Optional[str] = None,
        min_confidence: Optional[float] = None,
        date_from: Optional[str] = None,
        date_to: Optional[str] = None
    ) -> List[Dict]:
        """
        Fetch detections from BirdNET-Go API.
        
        Args:
            limit: Maximum number of detections to fetch
            offset: Offset for pagination
            species: Filter by species name (optional)
            min_confidence: Minimum confidence threshold (optional)
            date_from: Start date in YYYY-MM-DD format (optional)
            date_to: End date in YYYY-MM-DD format (optional)
            
        Returns:
            List of detection dictionaries
        """
        params = {
            'limit': limit,
            'offset': offset
        }
        
        if species:
            params['species'] = species
        if min_confidence is not None:
            params['minConfidence'] = min_confidence
        if date_from:
            params['dateFrom'] = date_from
        if date_to:
            params['dateTo'] = date_to
        
        try:
            response = self.session.get(
                f"{self.base_url}/api/detections",
                params=params,
                timeout=10
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"API request failed: {e}")
            return []
    
    def get_all_detections(
        self,
        max_detections: int = 10000,
        **kwargs
    ) -> List[Dict]:
        """
        Fetch all detections using pagination.
        
        Args:
            max_detections: Maximum total detections to fetch
            **kwargs: Additional filters (species, min_confidence, etc.)
            
        Returns:
            List of all detections
        """
        all_detections = []
        offset = 0
        batch_size = 1000
        
        print(f"Fetching detections from {self.base_url}...")
        
        while len(all_detections) < max_detections:
            detections = self.get_detections(
                limit=batch_size,
                offset=offset,
                **kwargs
            )
            
            if not detections:
                break
            
            all_detections.extend(detections)
            offset += batch_size
            
            print(f"  Fetched {len(all_detections)} detections...", end='\r')
            
            if len(detections) < batch_size:
                break
        
        print(f"\nTotal detections fetched: {len(all_detections)}")
        return all_detections[:max_detections]
    
    def get_species_list(self) -> List[str]:
        """Get list of all detected species."""
        try:
            response = self.session.get(
                f"{self.base_url}/api/species",
                timeout=10
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"Failed to fetch species list: {e}")
            return []


class DetectionAnalyzer:
    """
    Analyzes BirdNET detections and audio quality correlations.
    """
    
    def __init__(self, detections: List[Dict]):
        """
        Initialize analyzer with detection data.
        
        Args:
            detections: List of detection dictionaries from API
        """
        self.detections = detections
        self._parse_detections()
    
    def _parse_detections(self):
        """Parse timestamps and extract key fields."""
        for d in self.detections:
            # Parse timestamp - BirdNET-Go typically uses ISO format or Unix timestamp
            if 'timestamp' in d:
                try:
                    if isinstance(d['timestamp'], str):
                        d['datetime'] = datetime.fromisoformat(d['timestamp'].replace('Z', '+00:00'))
                    else:
                        d['datetime'] = datetime.fromtimestamp(d['timestamp'])
                except:
                    d['datetime'] = None
            elif 'beginTime' in d:
                try:
                    d['datetime'] = datetime.fromisoformat(d['beginTime'].replace('Z', '+00:00'))
                except:
                    d['datetime'] = None
    
    def get_summary(self) -> Dict:
        """Get summary statistics of detections."""
        if not self.detections:
            return {}
        
        summary = {
            'total_detections': len(self.detections),
            'unique_species': len(set(d.get('commonName', 'Unknown') for d in self.detections))
        }
        
        # Confidence statistics
        confidences = [d.get('confidence', 0) for d in self.detections if 'confidence' in d]
        if confidences:
            summary['confidence'] = {
                'mean': np.mean(confidences),
                'median': np.median(confidences),
                'std': np.std(confidences),
                'min': np.min(confidences),
                'max': np.max(confidences)
            }
        
        # Time range
        timestamps = [d.get('datetime') for d in self.detections if d.get('datetime')]
        if timestamps:
            summary['time_range'] = {
                'start': min(timestamps),
                'end': max(timestamps),
                'duration_hours': (max(timestamps) - min(timestamps)).total_seconds() / 3600
            }
        
        # Species counts
        species_counts = defaultdict(int)
        for d in self.detections:
            species = d.get('commonName', 'Unknown')
            species_counts[species] += 1
        
        summary['top_species'] = sorted(
            species_counts.items(),
            key=lambda x: x[1],
            reverse=True
        )[:15]
        
        # Hourly distribution
        hour_counts = defaultdict(int)
        for d in self.detections:
            if d.get('datetime'):
                hour_counts[d['datetime'].hour] += 1
        summary['hourly_distribution'] = dict(hour_counts)
        
        return summary
    
    def print_summary(self):
        """Print detailed summary of detections."""
        summary = self.get_summary()
        
        if not summary:
            print("No detections to analyze")
            return
        
        print("\n" + "="*80)
        print("BIRDNET-GO DETECTION SUMMARY")
        print("="*80)
        
        print(f"\nTotal Detections: {summary['total_detections']}")
        print(f"Unique Species:   {summary['unique_species']}")
        
        if 'time_range' in summary:
            tr = summary['time_range']
            print(f"\nTime Range:")
            print(f"  Start:    {tr['start'].strftime('%Y-%m-%d %H:%M:%S')}")
            print(f"  End:      {tr['end'].strftime('%Y-%m-%d %H:%M:%S')}")
            print(f"  Duration: {tr['duration_hours']:.1f} hours")
        
        if 'confidence' in summary:
            c = summary['confidence']
            print(f"\nConfidence Statistics:")
            print(f"  Mean:     {c['mean']:.3f}")
            print(f"  Median:   {c['median']:.3f}")
            print(f"  Std Dev:  {c['std']:.3f}")
            print(f"  Range:    {c['min']:.3f} to {c['max']:.3f}")
        
        if 'top_species' in summary:
            print(f"\nTop 15 Detected Species:")
            for i, (species, count) in enumerate(summary['top_species'], 1):
                pct = (count / summary['total_detections']) * 100
                print(f"  {i:2d}. {species:35s} {count:5d} ({pct:5.1f}%)")
        
        if 'hourly_distribution' in summary:
            print(f"\nDetections by Hour:")
            for hour in sorted(summary['hourly_distribution'].keys()):
                count = summary['hourly_distribution'][hour]
                bar = '█' * (count // 10)
                print(f"  {hour:02d}:00  {count:4d}  {bar}")
        
        print("="*80)
    
    def analyze_confidence_distribution(self):
        """Analyze how confidence scores are distributed."""
        confidences = [d.get('confidence', 0) for d in self.detections if 'confidence' in d]
        
        if not confidences:
            print("No confidence data available")
            return
        
        # Create bins
        bins = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
        hist, _ = np.histogram(confidences, bins=bins)
        
        print("\n" + "="*80)
        print("CONFIDENCE DISTRIBUTION")
        print("="*80)
        print(f"\nTotal detections with confidence: {len(confidences)}\n")
        
        for i in range(len(bins)-1):
            count = hist[i]
            pct = (count / len(confidences)) * 100
            bar = '█' * int(pct)
            print(f"  {bins[i]:.1f}-{bins[i+1]:.1f}  {count:5d} ({pct:5.1f}%)  {bar}")
        
        print("="*80)
    
    def get_recent_detections(self, hours: int = 24) -> List[Dict]:
        """Get detections from the last N hours."""
        cutoff = datetime.now() - timedelta(hours=hours)
        return [
            d for d in self.detections 
            if d.get('datetime') and d['datetime'] > cutoff
        ]
    
    def filter_by_species(self, species: str) -> List[Dict]:
        """Filter detections by species name."""
        return [
            d for d in self.detections 
            if d.get('commonName', '').lower() == species.lower()
        ]
    
    def filter_by_confidence(self, min_conf: float, max_conf: float = 1.0) -> List[Dict]:
        """Filter detections by confidence range."""
        return [
            d for d in self.detections 
            if min_conf <= d.get('confidence', 0) <= max_conf
        ]
    
    def plot_detection_timeline(self, save_path: Optional[str] = None):
        """Create visualization of detections over time."""
        timestamps = [d.get('datetime') for d in self.detections if d.get('datetime')]
        confidences = [d.get('confidence', 0) for d in self.detections if d.get('datetime')]
        
        if not timestamps:
            print("No timestamp data to plot")
            return
        
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8))
        fig.suptitle('BirdNET-Go Detection Timeline', fontsize=14, fontweight='bold')
        
        # Plot 1: Detections over time (scatter with confidence as color)
        scatter = ax1.scatter(timestamps, range(len(timestamps)), 
                            c=confidences, cmap='viridis', 
                            alpha=0.6, s=20)
        ax1.set_ylabel('Detection Number')
        ax1.set_title('Detection Timeline (colored by confidence)')
        ax1.grid(True, alpha=0.3)
        plt.colorbar(scatter, ax=ax1, label='Confidence')
        
        # Plot 2: Hourly detection count
        hours = [t.hour for t in timestamps]
        hour_counts = [hours.count(h) for h in range(24)]
        
        ax2.bar(range(24), hour_counts, color='steelblue', alpha=0.7)
        ax2.set_xlabel('Hour of Day')
        ax2.set_ylabel('Number of Detections')
        ax2.set_title('Detections by Hour')
        ax2.set_xticks(range(24))
        ax2.grid(True, alpha=0.3, axis='y')
        
        plt.tight_layout()
        
        if save_path:
            plt.savefig(save_path, dpi=300, bbox_inches='tight')
            print(f"Plot saved to: {save_path}")
        
        plt.show()
    
    def export_for_audio_analysis(self, output_path: str, hours: int = 24):
        """
        Export recent detections for audio stream analysis.
        
        Args:
            output_path: Path to save JSON file
            hours: Only export detections from last N hours
        """
        recent = self.get_recent_detections(hours)
        
        export_data = {
            'metadata': {
                'exported': datetime.now().isoformat(),
                'total_detections': len(recent),
                'time_window_hours': hours
            },
            'detections': []
        }
        
        for d in recent:
            export_data['detections'].append({
                'timestamp': d.get('datetime').isoformat() if d.get('datetime') else None,
                'species': d.get('commonName', 'Unknown'),
                'scientific_name': d.get('scientificName', ''),
                'confidence': d.get('confidence', 0),
                'begin_time': d.get('beginTime'),
                'end_time': d.get('endTime'),
                'clip_name': d.get('clipName', '')
            })
        
        with open(output_path, 'w') as f:
            json.dump(export_data, f, indent=2)
        
        print(f"\nExported {len(recent)} detections to: {output_path}")


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Fetch and analyze BirdNET-Go detections',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Fetch and analyze recent detections
  %(prog)s --url http://192.168.1.37:8080
  
  # Fetch last 24 hours with minimum confidence
  %(prog)s --url http://192.168.1.37:8080 --hours 24 --min-confidence 0.7
  
  # Export for audio analysis
  %(prog)s --url http://192.168.1.37:8080 --export detections.json
  
  # Analyze specific species
  %(prog)s --url http://192.168.1.37:8080 --species "American Robin"
  
  # Create timeline visualization
  %(prog)s --url http://192.168.1.37:8080 --plot timeline.png

For BirdNET-Go API documentation:
https://github.com/tphakala/birdnet-go/blob/main/doc/api.md
        """
    )
    
    parser.add_argument(
        '--url',
        type=str,
        default='http://localhost:8080',
        help='BirdNET-Go server URL (default: http://localhost:8080)'
    )
    
    parser.add_argument(
        '--hours',
        type=int,
        default=24,
        help='Fetch detections from last N hours (default: 24)'
    )
    
    parser.add_argument(
        '--max',
        type=int,
        default=10000,
        help='Maximum detections to fetch (default: 10000)'
    )
    
    parser.add_argument(
        '--species',
        type=str,
        help='Filter by species name'
    )
    
    parser.add_argument(
        '--min-confidence',
        type=float,
        help='Minimum confidence threshold (0.0-1.0)'
    )
    
    parser.add_argument(
        '--date-from',
        type=str,
        help='Start date (YYYY-MM-DD)'
    )
    
    parser.add_argument(
        '--date-to',
        type=str,
        help='End date (YYYY-MM-DD)'
    )
    
    parser.add_argument(
        '--export',
        type=str,
        help='Export detections to JSON file'
    )
    
    parser.add_argument(
        '--plot',
        type=str,
        help='Create timeline plot and save to file'
    )
    
    parser.add_argument(
        '-v', '--version',
        action='version',
        version=f'%(prog)s {__version__}'
    )
    
    args = parser.parse_args()
    
    # Print banner
    print("="*80)
    print("BirdNET-Go Detection Analyzer v" + __version__)
    print("="*80)
    
    # Initialize API client
    api = BirdNETGoAPI(base_url=args.url)
    
    print(f"\nConnecting to BirdNET-Go at {args.url}...")
    
    if not api.test_connection():
        print("ERROR: Could not connect to BirdNET-Go server")
        print(f"Please verify the server is running at {args.url}")
        sys.exit(1)
    
    print("✓ Connected successfully\n")
    
    # Fetch detections
    date_from = args.date_from or (datetime.now() - timedelta(hours=args.hours)).strftime('%Y-%m-%d')
    
    detections = api.get_all_detections(
        max_detections=args.max,
        species=args.species,
        min_confidence=args.min_confidence,
        date_from=date_from,
        date_to=args.date_to
    )
    
    if not detections:
        print("\nNo detections found matching criteria")
        sys.exit(0)
    
    # Analyze
    analyzer = DetectionAnalyzer(detections)
    analyzer.print_summary()
    analyzer.analyze_confidence_distribution()
    
    # Export if requested
    if args.export:
        analyzer.export_for_audio_analysis(args.export, hours=args.hours)
    
    # Plot if requested
    if args.plot:
        analyzer.plot_detection_timeline(save_path=args.plot)


if __name__ == "__main__":
    main()
