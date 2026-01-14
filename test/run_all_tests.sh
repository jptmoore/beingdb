#!/bin/bash
# Quick test runner script

set -e

echo "BeingDB Test Suite"
echo "=================="
echo ""

# Run unit tests
echo "→ Running unit tests..."
dune test

echo ""
echo "→ Setting up test data..."
chmod +x test/setup_test_data.sh
./test/setup_test_data.sh

echo ""
echo "→ Starting server in background..."
dune exec bin/main.exe -- --sync --port 8080 &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo ""
echo "→ Running integration tests..."
chmod +x test/integration_test.sh
if ./test/integration_test.sh; then
  TEST_RESULT=0
else
  TEST_RESULT=1
fi

echo ""
echo "→ Stopping server..."
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo ""
if [ $TEST_RESULT -eq 0 ]; then
  echo "✓ All tests passed!"
else
  echo "✗ Some tests failed"
fi

exit $TEST_RESULT
