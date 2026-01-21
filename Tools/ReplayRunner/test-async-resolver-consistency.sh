#!/bin/bash
# Tools/ReplayRunner/test-async-resolver-consistency.sh
#
# Script to test async resolver recording and re-evaluation consistency
# Now uses Swift Testing framework instead of standalone executable

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "🔍 Testing async resolver recording and re-evaluation consistency..."
echo ""

cd "$PROJECT_ROOT"

# Run the test using Swift Testing framework
echo "🚀 Running async resolver consistency test..."
echo ""

swift test --filter testAsyncResolverConsistency 2>&1

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "✅ Test passed - async resolver consistency verified!"
else
    echo ""
    echo "❌ Test failed - consistency check failed"
fi

exit $EXIT_CODE
