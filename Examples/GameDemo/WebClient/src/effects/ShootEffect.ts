import Phaser from "phaser";

/**
 * Creates visual effects for shooting
 */
export class ShootEffect {
  /**
   * Create a bullet trail effect from source to target
   */
  static createBulletTrail(
    scene: Phaser.Scene,
    fromX: number,
    fromY: number,
    toX: number,
    toY: number,
    color: number = 0xffff00,
    duration: number = 150
  ): void {
    // Create a line from source to target
    const line = scene.add.line(
      fromX,
      fromY,
      0,
      0,
      toX - fromX,
      toY - fromY,
      color,
      1.0
    );
    line.setLineWidth(2);
    line.setOrigin(0, 0);
    line.setDepth(100);

    // Animate the line
    scene.tweens.add({
      targets: line,
      alpha: 0,
      duration: duration,
      onComplete: () => line.destroy(),
    });

    // Add muzzle flash at source
    const flash = scene.add.circle(fromX, fromY, 1.5, color, 1.0);
    flash.setDepth(101);
    scene.tweens.add({
      targets: flash,
      alpha: 0,
      scale: 2,
      duration: duration * 0.3,
      onComplete: () => flash.destroy(),
    });

    // Add impact effect at target
    const impact = scene.add.circle(toX, toY, 0.8, color, 0.9);
    impact.setDepth(101);
    scene.tweens.add({
      targets: impact,
      alpha: 0,
      scale: 3,
      duration: duration * 0.5,
      onComplete: () => impact.destroy(),
    });
  }

  /**
   * Create a hit effect at target position
   */
  static createHitEffect(
    scene: Phaser.Scene,
    x: number,
    y: number,
    color: number = 0xff0000,
    duration: number = 300
  ): void {
    // Main hit circle
    const hitCircle = scene.add.circle(x, y, 1.5, color, 1.0);
    hitCircle.setDepth(102);

    // Outer ring
    const outerRing = scene.add.circle(x, y, 2.5, color, 0.6);
    outerRing.setDepth(102);

    // Animate both
    scene.tweens.add({
      targets: [hitCircle, outerRing],
      alpha: 0,
      scale: { from: 1, to: 2 },
      duration: duration,
      onComplete: () => {
        hitCircle.destroy();
        outerRing.destroy();
      },
    });

    // Add particles (small circles)
    for (let i = 0; i < 6; i++) {
      const angle = (i / 6) * Math.PI * 2;
      const distance = 1.5;
      const particle = scene.add.circle(
        x + Math.cos(angle) * distance,
        y + Math.sin(angle) * distance,
        0.3,
        color,
        1.0
      );
      particle.setDepth(102);

      scene.tweens.add({
        targets: particle,
        x: x + Math.cos(angle) * distance * 2,
        y: y + Math.sin(angle) * distance * 2,
        alpha: 0,
        duration: duration,
        onComplete: () => particle.destroy(),
      });
    }
  }

  /**
   * Create a turret fire effect
   */
  static createTurretFire(
    scene: Phaser.Scene,
    fromX: number,
    fromY: number,
    toX: number,
    toY: number,
    color: number = 0x00ffff,
    duration: number = 200
  ): void {
    // Turret bullet (smaller, different color)
    const line = scene.add.line(
      fromX,
      fromY,
      0,
      0,
      toX - fromX,
      toY - fromY,
      color,
      1.0
    );
    line.setLineWidth(1.5);
    line.setOrigin(0, 0);
    line.setDepth(100);

    scene.tweens.add({
      targets: line,
      alpha: 0,
      duration: duration,
      onComplete: () => line.destroy(),
    });

    // Turret muzzle flash
    const flash = scene.add.circle(fromX, fromY, 1.2, color, 0.8);
    flash.setDepth(101);
    scene.tweens.add({
      targets: flash,
      alpha: 0,
      scale: 1.5,
      duration: duration * 0.3,
      onComplete: () => flash.destroy(),
    });
  }
}
