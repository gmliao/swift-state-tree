export interface MetricsSummary {
    errorRate: number;
    disconnectRate: number;
    rttP95: number;
    rttP99: number;
    updateP95: number;
    updateP99: number;
}

export interface Thresholds {
    errorRate: number;
    disconnectRate: number;
    rttP95: number;
    rttP99: number;
    updateP95: number;
    updateP99: number;
}

export interface ThresholdResult {
    passed: boolean;
    failures: string[];
}

export function percentile(values: number[], p: number): number {
    if (values.length === 0) {
        return 0;
    }
    const sorted = [...values].sort((a, b) => a - b);
    const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1));
    return sorted[index];
}

export function evaluateThresholds(actual: MetricsSummary, thresholds: Thresholds): ThresholdResult {
    const failures: string[] = [];
    if (actual.errorRate > thresholds.errorRate) {
        failures.push(`errorRate ${actual.errorRate} > ${thresholds.errorRate}`);
    }
    if (actual.disconnectRate > thresholds.disconnectRate) {
        failures.push(`disconnectRate ${actual.disconnectRate} > ${thresholds.disconnectRate}`);
    }
    if (actual.rttP95 > thresholds.rttP95) {
        failures.push(`rttP95 ${actual.rttP95} > ${thresholds.rttP95}`);
    }
    if (actual.rttP99 > thresholds.rttP99) {
        failures.push(`rttP99 ${actual.rttP99} > ${thresholds.rttP99}`);
    }
    if (actual.updateP95 > thresholds.updateP95) {
        failures.push(`updateP95 ${actual.updateP95} > ${thresholds.updateP95}`);
    }
    if (actual.updateP99 > thresholds.updateP99) {
        failures.push(`updateP99 ${actual.updateP99} > ${thresholds.updateP99}`);
    }

    return { passed: failures.length === 0, failures };
}
