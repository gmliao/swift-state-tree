import { renderTemplate } from "./template";

export function renderTemplateObject(
    value: unknown,
    ctx: Record<string, string>
): any {
    if (typeof value === "string") {
        return renderTemplate(value, ctx);
    }
    if (Array.isArray(value)) {
        return value.map((entry) => renderTemplateObject(entry, ctx));
    }
    if (value && typeof value === "object") {
        const obj = value as Record<string, unknown>;
        const result: Record<string, unknown> = {};
        for (const [key, entry] of Object.entries(obj)) {
            result[key] = renderTemplateObject(entry, ctx);
        }
        return result;
    }
    return value;
}
