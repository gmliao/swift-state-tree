export type SendFn = (message: unknown, callback?: (error?: Error | null) => void) => boolean;

export function sendMessageWithAck(sendFn: SendFn, message: unknown, timeoutMs = 5000): Promise<void> {
    return new Promise((resolve, reject) => {
        let settled = false;
        const timeout = setTimeout(() => {
            if (settled) {
                return;
            }
            settled = true;
            reject(new Error("IPC send timed out"));
        }, timeoutMs);

        try {
            sendFn(message, (error?: Error | null) => {
                if (settled) {
                    return;
                }
                settled = true;
                clearTimeout(timeout);
                if (error) {
                    reject(error);
                } else {
                    resolve();
                }
            });
        } catch (error) {
            if (settled) {
                return;
            }
            settled = true;
            clearTimeout(timeout);
            reject(error instanceof Error ? error : new Error(String(error)));
        }
    });
}
