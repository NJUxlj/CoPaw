#!/bin/bash
# CoPaw development helper script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

cd "$PROJECT_ROOT"

show_help() {
    echo "CoPaw Development Helper"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  init        Initialize CoPaw working directory"
    echo "  start       Start the CoPaw server"
    echo "  test        Run all tests (skip slow)"
    echo "  test-all    Run all tests including slow"
    echo "  test-cov    Run tests with coverage"
    echo "  lint        Run pre-commit checks"
    echo "  install     Install dev dependencies"
    echo "  console     Start console frontend dev server"
    echo "  help        Show this help"
}

cmd_init() {
    echo "Initializing CoPaw..."
    copaw init --defaults
}

cmd_start() {
    echo "Starting CoPaw server..."
    copaw app
}

cmd_test() {
    echo "Running tests (skipping slow)..."
    pytest -m "not slow" -v
}

cmd_test_all() {
    echo "Running all tests..."
    pytest -v
}

cmd_test_cov() {
    echo "Running tests with coverage..."
    pytest --cov=copaw --cov-report=html -v
}

cmd_lint() {
    echo "Running pre-commit checks..."
    pre-commit run --all-files
}

cmd_install() {
    echo "Installing dev dependencies..."
    pip install -e ".[dev]"
}

cmd_console() {
    echo "Starting console frontend..."
    cd "$PROJECT_ROOT/console"
    npm ci && npm run dev
}

# Main
case "${1:-help}" in
    init)
        cmd_init
        ;;
    start)
        cmd_start
        ;;
    test)
        cmd_test
        ;;
    test-all)
        cmd_test_all
        ;;
    test-cov)
        cmd_test_cov
        ;;
    lint)
        cmd_lint
        ;;
    install)
        cmd_install
        ;;
    console)
        cmd_console
        ;;
    help|*)
        show_help
        ;;
esac
