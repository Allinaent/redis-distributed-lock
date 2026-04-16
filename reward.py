#!/usr/bin/env python3
"""
Reward function for redis-distributed-lock task.
Evaluates the solution based on test results.
"""

import json
import os


def reward() -> float:
    """
    Calculate reward based on test results.
    Returns a score between 0.0 and 1.0
    """
    report_path = "/app/test_report.txt"
    
    # Check if report exists
    if not os.path.exists(report_path):
        print(f"ERROR: {report_path} not found")
        return 0.0
    
    # Read the report
    with open(report_path, 'r') as f:
        content = f.read()
    
    # Count passed tests
    passed = content.count("PASSED")
    total = passed + content.count("FAILED")
    
    if total == 0:
        print("ERROR: No tests found in report")
        return 0.0
    
    score = passed / total
    print(f"Tests passed: {passed}/{total} = {score:.2f}")
    
    return score


if __name__ == "__main__":
    result = reward()
    print(f"Final score: {result}")
