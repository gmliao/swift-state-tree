/**
 * DeterministicMath classes for TypeScript SDK.
 * These classes mirror Swift's DeterministicMath types, storing fixed-point integers
 * internally and automatically converting to floats via getters.
 */

// Fixed-point scale factor (must match Swift FixedPoint.scale)
export const FIXED_POINT_SCALE = 1000

/**
 * 2D integer vector for deterministic math.
 * Internally stores fixed-point integers, getters automatically convert to float.
 * Similar to Swift's IVec2 struct.
 */
export class IVec2 {
  private _x: number
  private _y: number
  
  /**
   * Create IVec2 from fixed-point integers or floats.
   * @param x - X coordinate (fixed-point integer if isFixedPoint=true, float otherwise)
   * @param y - Y coordinate (fixed-point integer if isFixedPoint=true, float otherwise)
   * @param isFixedPoint - Whether x and y are fixed-point integers (default: true)
   */
  constructor(x: number, y: number, isFixedPoint: boolean = true) {
    if (isFixedPoint) {
      this._x = x
      this._y = y
    } else {
      this._x = Math.round(x * FIXED_POINT_SCALE)
      this._y = Math.round(y * FIXED_POINT_SCALE)
    }
  }
  
  /**
   * Get x coordinate as float (automatically converted from fixed-point).
   */
  get x(): number {
    return this._x / FIXED_POINT_SCALE
  }
  
  /**
   * Set x coordinate from float (automatically converted to fixed-point).
   */
  set x(value: number) {
    this._x = Math.round(value * FIXED_POINT_SCALE)
  }
  
  /**
   * Get y coordinate as float (automatically converted from fixed-point).
   */
  get y(): number {
    return this._y / FIXED_POINT_SCALE
  }
  
  /**
   * Set y coordinate from float (automatically converted to fixed-point).
   */
  set y(value: number) {
    this._y = Math.round(value * FIXED_POINT_SCALE)
  }
  
  /**
   * Get raw x coordinate as fixed-point integer (for serialization).
   */
  get rawX(): number {
    return this._x
  }
  
  /**
   * Get raw y coordinate as fixed-point integer (for serialization).
   */
  get rawY(): number {
    return this._y
  }
  
  /**
   * Convert to JSON format for serialization (returns fixed-point integers).
   */
  toJSON(): { x: number; y: number } {
    return { x: this._x, y: this._y }
  }
}

/**
 * 3D integer vector for deterministic math.
 * Internally stores fixed-point integers, getters automatically convert to float.
 */
export class IVec3 {
  private _x: number
  private _y: number
  private _z: number
  
  constructor(x: number, y: number, z: number, isFixedPoint: boolean = true) {
    if (isFixedPoint) {
      this._x = x
      this._y = y
      this._z = z
    } else {
      this._x = Math.round(x * FIXED_POINT_SCALE)
      this._y = Math.round(y * FIXED_POINT_SCALE)
      this._z = Math.round(z * FIXED_POINT_SCALE)
    }
  }
  
  get x(): number {
    return this._x / FIXED_POINT_SCALE
  }
  
  set x(value: number) {
    this._x = Math.round(value * FIXED_POINT_SCALE)
  }
  
  get y(): number {
    return this._y / FIXED_POINT_SCALE
  }
  
  set y(value: number) {
    this._y = Math.round(value * FIXED_POINT_SCALE)
  }
  
  get z(): number {
    return this._z / FIXED_POINT_SCALE
  }
  
  set z(value: number) {
    this._z = Math.round(value * FIXED_POINT_SCALE)
  }
  
  get rawX(): number {
    return this._x
  }
  
  get rawY(): number {
    return this._y
  }
  
  get rawZ(): number {
    return this._z
  }
  
  toJSON(): { x: number; y: number; z: number } {
    return { x: this._x, y: this._y, z: this._z }
  }
}

/**
 * Angle for deterministic math.
 * Internally stores fixed-point integer degrees, getter automatically converts to float.
 */
export class Angle {
  private _degrees: number
  
  /**
   * Create Angle from fixed-point integer degrees or float degrees.
   * @param degrees - Angle in degrees (fixed-point integer if isFixedPoint=true, float otherwise)
   * @param isFixedPoint - Whether degrees is fixed-point integer (default: true)
   */
  constructor(degrees: number, isFixedPoint: boolean = true) {
    if (isFixedPoint) {
      this._degrees = degrees
    } else {
      this._degrees = Math.round(degrees * FIXED_POINT_SCALE)
    }
  }
  
  /**
   * Get degrees as float (automatically converted from fixed-point).
   */
  get degrees(): number {
    return this._degrees / FIXED_POINT_SCALE
  }
  
  /**
   * Set degrees from float (automatically converted to fixed-point).
   */
  set degrees(value: number) {
    this._degrees = Math.round(value * FIXED_POINT_SCALE)
  }
  
  /**
   * Get raw degrees as fixed-point integer (for serialization).
   */
  get rawDegrees(): number {
    return this._degrees
  }
  
  /**
   * Convert to radians.
   */
  toRadians(): number {
    return this.degrees * Math.PI / 180
  }
  
  /**
   * Convert to JSON format for serialization (returns fixed-point integer).
   */
  toJSON(): { degrees: number } {
    return { degrees: this._degrees }
  }
}

/**
 * Base class for semantic types (Position2, Velocity2, Acceleration2).
 * Wraps IVec2 instance, provides automatic float conversion.
 */
export class Semantic2 {
  protected _v: IVec2
  
  /**
   * Create Semantic2 from IVec2 instance or fixed-point integers.
   */
  constructor(v: IVec2 | { x: number; y: number }, isFixedPoint: boolean = true) {
    if (v instanceof IVec2) {
      this._v = v
    } else {
      this._v = new IVec2(v.x, v.y, isFixedPoint)
    }
  }
  
  /**
   * Get IVec2 instance (automatically converts to float when accessing x/y).
   */
  get v(): IVec2 {
    return this._v
  }
  
  /**
   * Set IVec2 instance.
   */
  set v(value: IVec2) {
    this._v = value
  }
  
  /**
   * Convert to JSON format for serialization (returns fixed-point integers).
   */
  toJSON(): { v: { x: number; y: number } } {
    return { v: this._v.toJSON() }
  }
}

/**
 * Position2 - semantic type wrapping IVec2.
 * Internally stores IVec2 instance, provides automatic float conversion.
 */
export class Position2 extends Semantic2 {}

/**
 * Velocity2 - semantic type wrapping IVec2.
 * Internally stores IVec2 instance, provides automatic float conversion.
 */
export class Velocity2 extends Semantic2 {}

/**
 * Acceleration2 - semantic type wrapping IVec2.
 * Internally stores IVec2 instance, provides automatic float conversion.
 */
export class Acceleration2 extends Semantic2 {}
