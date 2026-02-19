import Phaser from "phaser";
import type { HeroDefenseStateTree } from "../generated/hero-defense/index";
import type { HeroDefenseState } from "../generated/defs";
import { Position2 } from "../generated/defs";
import { Grid } from "../graphics/Grid";
import { MoveToInputHandler } from "../input/MoveToInputHandler";
import { PlaceTurretInputHandler } from "../input/PlaceTurretInputHandler";
import { PlayerManager } from "../managers/PlayerManager";
import { MonsterManager } from "../managers/MonsterManager";
import { TurretManager } from "../managers/TurretManager";
import { BaseManager } from "../managers/BaseManager";
import { HUDManager } from "../managers/HUDManager";
import { CameraManager } from "../managers/CameraManager";
import { EffectManager } from "../managers/EffectManager";

export class GameScene extends Phaser.Scene {
  private tree: HeroDefenseStateTree | null = null;
  private replayMode = false;
  private cameraManager!: CameraManager;
  private moveInput!: MoveToInputHandler;
  private placeTurretInput!: PlaceTurretInputHandler;
  private playerManager!: PlayerManager;
  private monsterManager!: MonsterManager;
  private turretManager!: TurretManager;
  private baseManager!: BaseManager;
  private hudManager!: HUDManager;
  private effectManager!: EffectManager;
  private grid!: Grid;

  constructor() {
    super({ key: "GameScene" });
  }

  setStateTree(tree: HeroDefenseStateTree) {
    this.tree = tree;

    // Subscribe to server events for visual effects
    if (this.effectManager) {
      this.effectManager.subscribeToTree(tree);
    }

    // If scene is already created, update HUD immediately and setup camera follow
    if (this.hudManager) {
      this.updateFromState();

      // Subscribe player manager to tree for onAdd/onRemove events
      // tree.currentPlayerID is automatically used
      if (this.playerManager) {
        this.playerManager.subscribeToTree(tree);
      }

      // Setup camera follow on next frame to ensure sprites are created
      if (this.cameraManager) {
        this.cameraManager.setDependencies(tree, this.playerManager);
        this.time.delayedCall(0, () => {
          this.cameraManager.setupFollow();
        });
      }
    }
  }

  setReplayMode(enabled: boolean) {
    this.replayMode = enabled;
    if (this.cameraManager) {
      this.cameraManager.setReplayMode(enabled);
    }
  }


  create() {
    // Initialize camera manager
    this.cameraManager = new CameraManager(this);
    this.cameraManager.setReplayMode(this.replayMode);

    // Create white background covering a large area
    const backgroundSize = 1000;
    this.add.rectangle(0, 0, backgroundSize, backgroundSize, 0xffffff);

    // Create grid background
    this.grid = new Grid(this).create();

    // Initialize HUD manager (handles score, resources, position overlay)
    this.hudManager = new HUDManager(this);

    // Initialize effect manager (handles visual effects from server events)
    this.effectManager = new EffectManager(this);

    // Initialize base manager (handles base sprite and health text)
    this.baseManager = new BaseManager(this);

    // Initialize move-to input handler (left-click)
    this.moveInput = new MoveToInputHandler(this).init(
      (screenX, screenY) => this.cameraManager.screenToWorld(screenX, screenY),
      async (target) => {
        if (this.replayMode) {
          this.cameraManager.stopFollow();
          this.cameraManager.centerOn(target.x, target.y);
          return;
        }
        if (this.tree && !this.placeTurretInput.isInPlacementMode()) {
          const position = new Position2({ x: target.x, y: target.y }, false);
          await this.tree.events.moveTo({ target: position });
        }
      }
    );

    // Note: Shooting is now automatic (handled in server Tick)
    // No manual shoot input handler needed

    // Initialize place turret input handler (T key + click)
    this.placeTurretInput = new PlaceTurretInputHandler(this).init(
      (screenX, screenY) => this.cameraManager.screenToWorld(screenX, screenY),
      async (target) => {
        if (this.replayMode) {
          return;
        }
        if (this.tree) {
          const position = new Position2({ x: target.x, y: target.y }, false);
          await this.tree.events.placeTurret({ position: position });
        }
      }
    );

    // Initialize player manager
    this.playerManager = new PlayerManager(this).onCurrentPlayerUpdated(
      (player, serverPos) => {
        this.cameraManager.startFollow(player.container);
        this.hudManager.updatePosition(serverPos.x, serverPos.y);
      }
    );

    // Initialize monster manager
    this.monsterManager = new MonsterManager(this);

    // Initialize turret manager
    this.turretManager = new TurretManager(this);

    // Subscribe to tree if available (for onAdd/onRemove events)
    // tree.currentPlayerID is automatically used
    if (this.tree) {
      this.playerManager.subscribeToTree(this.tree);
      // Subscribe to server events for visual effects
      this.effectManager.subscribeToTree(this.tree);
      // Set camera manager dependencies
      this.cameraManager.setDependencies(this.tree, this.playerManager);
      this.cameraManager.setupFollow();
    }

    // Update from state if available
    if (this.tree) {
      this.updateFromState();
    }
  }

  update() {
    if (!this.tree) return;

    const state = this.tree.state as HeroDefenseState;

    // Update player manager with current player ID (from tree)
    if (this.tree.currentPlayerID) {
      this.playerManager.setCurrentPlayerID(this.tree.currentPlayerID);
    }

    // Update all players (handles creation, updates, and removal)
    this.playerManager.update(state.players || {});

    // Update monsters
    this.monsterManager.update(state.monsters);

    // Update turrets
    this.turretManager.update(state.turrets);

    // Update base
    this.baseManager.update(state.base);

    // Update UI
    this.updateFromState();
  }

  private updateFromState() {
    if (!this.tree) return;

    // Direct access to underlying state (no Vue reactivity)
    const currentState = this.tree.state as HeroDefenseState;
    if (!currentState) return;

    // Update HUD (score, resources, etc.)
    this.hudManager.update(currentState, this.tree.currentPlayerID);

    // Base health text is updated by BaseManager in updateFromState
  }

  /** Get the grid instance (for external control) */
  getGrid(): Grid {
    return this.grid;
  }

  /** Get the move input handler (for external control) */
  getMoveInput(): MoveToInputHandler {
    return this.moveInput;
  }

  /** Get the place turret input handler (for external control) */
  getPlaceTurretInput(): PlaceTurretInputHandler {
    return this.placeTurretInput;
  }

  /** Get the tree instance (for external control) */
  getTree(): HeroDefenseStateTree | null {
    return this.tree;
  }
}
