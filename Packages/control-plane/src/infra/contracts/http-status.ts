/**
 * HTTP status codes for branching and lookup.
 * Use Response.ok for 2xx success check; use this enum when branching on specific codes.
 */

export enum HttpStatusCode {
  Ok = 200,
  Created = 201,
  NoContent = 204,
  BadRequest = 400,
  Unauthorized = 401,
  NotFound = 404,
  InternalServerError = 500,
  ServiceUnavailable = 503,
}

/** True when status is 2xx. Prefer Response.ok from fetch. */
export function isHttpSuccess(status: number): boolean {
  return status >= 200 && status < 300;
}

/** Look up enum for known codes. */
export function httpStatusCodeFrom(status: number): HttpStatusCode | undefined {
  return Object.values(HttpStatusCode).includes(status as HttpStatusCode)
    ? (status as HttpStatusCode)
    : undefined;
}
