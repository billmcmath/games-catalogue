#!/bin/bash

# Extract Python runtime from Terraform
PYTHON_VERSION=$(grep -A 3 'variable "python_version"' main.tf | grep 'default.*=' | grep -o 'python[0-9.]*' | sed 's/python//')

if [ -z "$PYTHON_VERSION" ]; then
    echo "Error: Could not find Python version in Terraform config"
    exit 1
fi

PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)
PYTHON_DIR="python${PYTHON_MAJOR}.${PYTHON_MINOR}"

echo "Building layer for Python $PYTHON_VERSION..."

rm -rf lambda_layer/python lambda_layer.zip
mkdir -p lambda_layer/python/lib/$PYTHON_DIR/site-packages

pip install -r requirements.txt -t lambda_layer/python/lib/$PYTHON_DIR/site-packages/

echo "Layer built successfully in lambda_layer/python/lib/$PYTHON_DIR/site-packages"