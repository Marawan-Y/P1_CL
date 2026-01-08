"""
Paint Shop Production Sequence Optimizer
Uses Mixed-Integer Linear Programming (MILP) to minimize changeovers
and level-load paint distribution across production batches.

Author: Demand Planning Team
Date: January 2026
"""

import pandas as pd
import numpy as np
from pulp import *
from datetime import datetime, timedelta
import warnings
warnings.filterwarnings('ignore')


class PaintShopOptimizer:
    """
    Optimizes vehicle production sequence for paint shop efficiency.
    Minimizes changeovers while level-loading paint distribution.
    """
    
    def __init__(self, batch_size=20):
        """
        Initialize optimizer with batch size.
        
        Args:
            batch_size (int): Number of vehicles per paint batch (default: 20)
        """
        self.batch_size = batch_size
        self.vehicles_df = None
        self.paint_summary = None
        self.solution_df = None
        self.num_changeovers = 0
        
    def load_data(self, file_path, sheet_name='vehicle_table'):
        """
        Load vehicle data from Excel file.
        
        Args:
            file_path (str): Path to Excel file
            sheet_name (str): Name of sheet containing vehicle data
            
        Returns:
            pd.DataFrame: Loaded vehicle data
        """
        print(f"Loading data from {file_path}...")
        self.vehicles_df = pd.read_excel(file_path, sheet_name=sheet_name)
        print(f"Loaded {len(self.vehicles_df)} vehicles")
        return self.vehicles_df
    
    def analyze_paint_distribution(self):
        """
        Analyze paint distribution and calculate batch requirements.
        
        Returns:
            pd.DataFrame: Summary of paint codes with batch calculations
        """
        print("\nAnalyzing paint distribution...")
        
        paint_counts = self.vehicles_df['paint'].value_counts().reset_index()
        paint_counts.columns = ['paint_code', 'vehicle_count']
        
        # Calculate full batches and remainders
        paint_counts['full_batches'] = paint_counts['vehicle_count'] // self.batch_size
        paint_counts['remainder'] = paint_counts['vehicle_count'] % self.batch_size
        paint_counts['total_batches'] = np.ceil(paint_counts['vehicle_count'] / self.batch_size).astype(int)
        
        self.paint_summary = paint_counts.sort_values('vehicle_count', ascending=False)
        
        print(f"\nPaint Distribution Summary:")
        print(f"Unique paint codes: {len(self.paint_summary)}")
        print(f"Total vehicles: {self.paint_summary['vehicle_count'].sum()}")
        print(f"Total batches required: {self.paint_summary['total_batches'].sum()}")
        print("\nTop 5 paint codes:")
        print(self.paint_summary.head())
        
        return self.paint_summary
    
    def calculate_ideal_positions(self, paint_code, num_batches, total_batches):
        """
        Calculate ideal evenly-spaced positions for a paint code's batches.
        
        Args:
            paint_code (str): Paint code
            num_batches (int): Number of batches for this paint
            total_batches (int): Total number of batches in schedule
            
        Returns:
            list: Ideal batch positions (0-indexed)
        """
        if num_batches == 1:
            return [total_batches // 2]
        
        # Evenly space batches across the production schedule
        spacing = total_batches / num_batches
        positions = [int(i * spacing) for i in range(num_batches)]
        return positions
    
    def optimize_sequence_milp(self):
        """
        Optimize production sequence using Mixed-Integer Linear Programming.
        
        Returns:
            pd.DataFrame: Optimized vehicle sequence
        """
        print("\n" + "="*60)
        print("Starting MILP Optimization")
        print("="*60)
        
        if self.paint_summary is None:
            self.analyze_paint_distribution()
        
        # Prepare data structures
        paint_codes = self.paint_summary['paint_code'].tolist()
        paint_batches = dict(zip(
            self.paint_summary['paint_code'], 
            self.paint_summary['total_batches']
        ))
        total_batches = self.paint_summary['total_batches'].sum()
        
        print(f"\nProblem Size:")
        print(f"  Paint codes: {len(paint_codes)}")
        print(f"  Total batches: {total_batches}")
        print(f"  Decision variables: ~{len(paint_codes) * total_batches}")
        
        # Calculate ideal positions for each paint code
        ideal_positions = {}
        for paint in paint_codes:
            num_batches = paint_batches[paint]
            ideal_positions[paint] = self.calculate_ideal_positions(
                paint, num_batches, total_batches
            )
        
        # Create MILP problem
        print("\nBuilding MILP model...")
        prob = LpProblem("PaintShop_Optimization", LpMinimize)
        
        # Decision Variables
        # x[c,b] = 1 if batch b is assigned to paint c
        x = LpVariable.dicts("batch_assignment",
                            ((c, b) for c in paint_codes for b in range(total_batches)),
                            cat='Binary')
        
        # y[b] = 1 if there's a changeover at batch b
        y = LpVariable.dicts("changeover",
                            range(total_batches),
                            cat='Binary')
        
        # Auxiliary variables for level-loading penalty
        dev = LpVariable.dicts("deviation",
                              ((c, i, b) for c in paint_codes 
                               for i in range(paint_batches[c])
                               for b in range(total_batches)),
                              lowBound=0,
                              cat='Continuous')
        
        print("Building constraints...")
        
        # Constraint 1: Each batch assigned to exactly one paint
        for b in range(total_batches):
            prob += lpSum([x[c, b] for c in paint_codes]) == 1, f"one_paint_per_batch_{b}"
        
        # Constraint 2: Each paint gets its required number of batches
        for c in paint_codes:
            prob += lpSum([x[c, b] for b in range(total_batches)]) == paint_batches[c], \
                    f"batch_count_{c}"
        
        # Constraint 3: Changeover detection
        for b in range(1, total_batches):
            for c in paint_codes:
                prob += y[b] >= x[c, b] - x[c, b-1], f"changeover_detect_{c}_{b}"
        
        # First batch is always a "changeover" (setup)
        prob += y[0] == 1, "first_batch_setup"
        
        # Constraint 4: Level-loading deviation calculation
        # For each paint's i-th batch, calculate distance from ideal position
        for c in paint_codes:
            for i in range(paint_batches[c]):
                ideal_pos = ideal_positions[c][i]
                for b in range(total_batches):
                    # dev[c,i,b] >= |b - ideal_pos| * x[c,b]
                    prob += dev[c, i, b] >= (b - ideal_pos) * x[c, b], \
                            f"dev_pos_{c}_{i}_{b}"
                    prob += dev[c, i, b] >= (ideal_pos - b) * x[c, b], \
                            f"dev_neg_{c}_{i}_{b}"
        
        # Objective Function: Minimize changeovers + level-loading penalty
        changeover_weight = 1000  # High weight for changeovers
        levelload_weight = 1      # Lower weight for spacing deviations
        
        prob += (
            changeover_weight * lpSum([y[b] for b in range(total_batches)]) +
            levelload_weight * lpSum([dev[c, i, b] 
                                     for c in paint_codes 
                                     for i in range(paint_batches[c])
                                     for b in range(total_batches)])
        ), "minimize_changeovers_and_levelload"
        
        # Solve the problem
        print("\nSolving MILP... (this may take a minute)")
        print("Using CBC solver...")
        
        solver = PULP_CBC_CMD(msg=1, timeLimit=300)  # 5 minute time limit
        prob.solve(solver)
        
        # Check solution status
        print(f"\nSolution Status: {LpStatus[prob.status]}")
        
        if prob.status != LpStatusOptimal:
            print("Warning: Optimal solution not found. Using best feasible solution.")
        
        # Extract solution
        print("\nExtracting solution...")
        batch_assignments = []
        
        for b in range(total_batches):
            for c in paint_codes:
                if value(x[c, b]) > 0.5:  # Binary variable, check if assigned
                    batch_assignments.append({
                        'batch_position': b,
                        'paint_code': c
                    })
                    break
        
        batch_df = pd.DataFrame(batch_assignments)
        
        # Calculate changeovers
        self.num_changeovers = sum(1 for b in range(total_batches) if value(y[b]) > 0.5)
        
        print(f"\nOptimization Results:")
        print(f"  Total changeovers: {self.num_changeovers}")
        print(f"  Objective value: {value(prob.objective):.2f}")
        
        return batch_df
    
    def assign_vehicles_to_batches(self, batch_sequence):
        """
        Assign individual vehicles to optimized batch positions.
        
        Args:
            batch_sequence (pd.DataFrame): Optimized batch sequence
            
        Returns:
            pd.DataFrame: Vehicle assignments with new production sequence
        """
        print("\nAssigning vehicles to optimized batches...")
        
        # Sort batch sequence by position
        batch_sequence = batch_sequence.sort_values('batch_position').reset_index(drop=True)
        
        # Create vehicle assignments
        vehicle_assignments = []
        current_seq = 1
        
        for idx, batch in batch_sequence.iterrows():
            paint = batch['paint_code']
            batch_pos = batch['batch_position']
            
            # Get vehicles for this paint (up to batch_size)
            paint_vehicles = self.vehicles_df[
                (self.vehicles_df['paint'] == paint) & 
                (~self.vehicles_df['vin'].isin([v['vin'] for v in vehicle_assignments]))
            ].head(self.batch_size)
            
            # Assign vehicles maintaining their relative order within batch
            for _, vehicle in paint_vehicles.iterrows():
                vehicle_assignments.append({
                    'vin': vehicle['vin'],
                    'paint': vehicle['paint'],
                    'batch_id': batch_pos + 1,  # 1-indexed batch ID
                    'production_sequence': current_seq,
                    'original_sequence': vehicle['production_sequence']
                })
                current_seq += 1
        
        self.solution_df = pd.DataFrame(vehicle_assignments)
        
        print(f"Assigned {len(self.solution_df)} vehicles to {len(batch_sequence)} batches")
        
        return self.solution_df
    
    def update_timestamps(self, start_datetime=None, increment_minutes=1):
        """
        Update planned_ga_in_datetime based on new production sequence.
        
        Args:
            start_datetime (datetime): Starting datetime (default: from original data)
            increment_minutes (int): Minutes between each vehicle (default: 1)
            
        Returns:
            pd.DataFrame: Solution with updated timestamps
        """
        if start_datetime is None:
            # Use original start time from data
            start_datetime = pd.to_datetime(self.vehicles_df['planned_ga_in_datetime'].min())
        
        self.solution_df['planned_ga_in_datetime'] = [
            start_datetime + timedelta(minutes=i * increment_minutes)
            for i in range(len(self.solution_df))
        ]
        
        return self.solution_df
    
    def generate_summary_metrics(self):
        """
        Generate summary metrics for the optimization.
        
        Returns:
            dict: Summary statistics
        """
        if self.solution_df is None:
            raise ValueError("No solution available. Run optimization first.")
        
        # Calculate metrics
        total_vehicles = len(self.solution_df)
        unique_paints = self.solution_df['paint'].nunique()
        total_batches = self.solution_df['batch_id'].nunique()
        
        # Paint distribution per 100 units
        paint_dist = self.solution_df.groupby('paint').size()
        paint_per_100 = (paint_dist / total_vehicles * 100).to_dict()
        
        # Changeover analysis
        changeovers = []
        prev_paint = None
        for _, row in self.solution_df.iterrows():
            if prev_paint is not None and row['paint'] != prev_paint:
                changeovers.append(row['production_sequence'])
            prev_paint = row['paint']
        
        metrics = {
            'total_vehicles': total_vehicles,
            'unique_paint_codes': unique_paints,
            'total_batches': total_batches,
            'total_changeovers': len(changeovers),
            'changeover_rate': len(changeovers) / total_batches * 100,
            'paint_distribution_per_100': paint_per_100,
            'changeover_positions': changeovers
        }
        
        return metrics
    
    def export_results(self, output_file='optimized_sequence.xlsx'):
        """
        Export optimized sequence to Excel file.
        
        Args:
            output_file (str): Output file path
        """
        print(f"\nExporting results to {output_file}...")
        
        with pd.ExcelWriter(output_file, engine='openpyxl') as writer:
            # Sheet 1: Optimized sequence (answer to Question 2)
            output_cols = ['vin', 'paint', 'production_sequence']
            self.solution_df[output_cols].to_excel(
                writer, 
                sheet_name='Optimized_Sequence',
                index=False
            )
            
            # Sheet 2: Paint summary (answer to Question 1)
            self.paint_summary.to_excel(
                writer,
                sheet_name='Paint_Summary',
                index=False
            )
            
            # Sheet 3: Metrics
            metrics = self.generate_summary_metrics()
            metrics_df = pd.DataFrame([
                {'Metric': 'Total Vehicles', 'Value': metrics['total_vehicles']},
                {'Metric': 'Unique Paint Codes', 'Value': metrics['unique_paint_codes']},
                {'Metric': 'Total Batches', 'Value': metrics['total_batches']},
                {'Metric': 'Total Changeovers', 'Value': metrics['total_changeovers']},
                {'Metric': 'Changeover Rate (%)', 'Value': f"{metrics['changeover_rate']:.2f}"}
            ])
            metrics_df.to_excel(writer, sheet_name='Metrics', index=False)
            
            # Sheet 4: Full solution with all details
            self.solution_df.to_excel(
                writer,
                sheet_name='Full_Solution',
                index=False
            )
        
        print(f"Results exported successfully!")
    
    def run_full_optimization(self, input_file, output_file='optimized_sequence.xlsx'):
        """
        Run complete optimization workflow.
        
        Args:
            input_file (str): Input Excel file path
            output_file (str): Output Excel file path
            
        Returns:
            tuple: (solution_df, metrics_dict)
        """
        print("\n" + "="*60)
        print("PAINT SHOP PRODUCTION SEQUENCE OPTIMIZER")
        print("="*60)
        
        # Step 1: Load data
        self.load_data(input_file)
        
        # Step 2: Analyze paint distribution
        paint_summary = self.analyze_paint_distribution()
        
        # Step 3: Optimize using MILP
        batch_sequence = self.optimize_sequence_milp()
        
        # Step 4: Assign vehicles to batches
        solution = self.assign_vehicles_to_batches(batch_sequence)
        
        # Step 5: Update timestamps
        self.update_timestamps()
        
        # Step 6: Generate metrics
        metrics = self.generate_summary_metrics()
        
        # Step 7: Export results
        self.export_results(output_file)
        
        # Print final summary
        print("\n" + "="*60)
        print("OPTIMIZATION COMPLETE - FINAL SUMMARY")
        print("="*60)
        print(f"\n📊 ANSWER TO QUESTION 1:")
        print(f"   Unique paint options available: {metrics['unique_paint_codes']}")
        print(f"\n📋 ANSWER TO QUESTION 2:")
        print(f"   Optimal VIN sequence exported to: {output_file}")
        print(f"   (See 'Optimized_Sequence' sheet)")
        print(f"\n🎯 OPTIMIZATION METRICS:")
        print(f"   Total vehicles processed: {metrics['total_vehicles']}")
        print(f"   Total batches created: {metrics['total_batches']}")
        print(f"   Paint changeovers: {metrics['total_changeovers']}")
        print(f"   Changeover rate: {metrics['changeover_rate']:.2f}%")
        print(f"\n✅ All results saved to: {output_file}")
        print("="*60)
        
        return solution, metrics


def main():
    """
    Main execution function.
    """
    # Initialize optimizer
    optimizer = PaintShopOptimizer(batch_size=20)
    
    # Run optimization
    # Update the file path to your input Excel file
    input_file = 'vehicle_table.xlsx'  # Change this to your file path
    output_file = 'optimized_paint_sequence.xlsx'
    
    try:
        solution, metrics = optimizer.run_full_optimization(input_file, output_file)
        
        # Display sample of optimized sequence
        print("\n📝 Sample of Optimized Sequence (first 10 vehicles):")
        print(solution[['vin', 'paint', 'production_sequence']].head(10).to_string(index=False))
        
    except FileNotFoundError:
        print(f"\n❌ Error: Could not find input file '{input_file}'")
        print("Please update the 'input_file' variable with the correct path.")
    except Exception as e:
        print(f"\n❌ Error during optimization: {str(e)}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    main()
