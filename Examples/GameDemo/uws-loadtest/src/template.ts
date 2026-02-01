export function renderTemplate(value: string, ctx: Record<string, string>): string {
    return value.replace(/\{([^}]+)\}/g, (match, token) => {
        if (token.startsWith("randInt:")) {
            const parts = token.split(":");
            const min = Number(parts[1]);
            const max = Number(parts[2]);
            if (Number.isFinite(min) && Number.isFinite(max) && max >= min) {
                const rand = Math.floor(Math.random() * (max - min + 1)) + min;
                return String(rand);
            }
            return match;
        }

        const replacement = ctx[token];
        return replacement !== undefined ? replacement : match;
    });
}
