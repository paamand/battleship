import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  runApp(const BattleshipApp());
}

class BattleshipApp extends StatelessWidget {
  const BattleshipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sketch Battleship',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.light(
          primary: Colors.black,
          secondary: Colors.black,
          surface: Colors.white,
          onPrimary: Colors.white,
          onSurface: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const BattleshipGamePage(),
    );
  }
}

enum ShipSection { front, middle, aft }

class ShipState {
  ShipState({required this.id, required this.position, required this.heading});

  final int id;
  Offset position;
  Offset velocity = Offset.zero;
  Offset? dragTarget;
  double heading;
  bool frontHit = false;
  bool middleHit = false;
  bool aftHit = false;
  bool sunk = false;
  int score = 0;
  double missileCooldown = 0;
  double torpedoCooldown = 0;
  int respawnVersion = 0;
  double mineCooldown = 0.0;

  bool get canMove => !sunk && !aftHit;
  bool get canFireCannon => !sunk && !frontHit;
  bool get canFireTorpedo => !sunk;
}

class Missile {
  Missile({required this.ownerId, required this.start, required this.target});

  final int ownerId;
  final Offset start;
  final Offset target;
  double progress = 0.0;

  Offset get position => Offset.lerp(start, target, progress)!;
}

class Torpedo {
  Torpedo({
    required this.ownerId,
    required this.position,
    required this.direction,
  }) : previousPosition = position;

  final int ownerId;
  Offset position;
  Offset previousPosition;
  Offset direction;
}

class Mine {
  Mine({required this.ownerId, required this.position, this.ttl = 30});

  final int ownerId;
  Offset position;
  double ttl;
}

class HitMarker {
  HitMarker({required this.position, this.ttl = 4.0, this.big = false});

  final Offset position;
  double ttl;
  final bool big;
}

class WorldViewport {
  const WorldViewport({
    required this.worldSize,
    required this.scale,
    required this.offset,
  });

  final Size worldSize;
  final double scale;
  final Offset offset;

  factory WorldViewport.fit(Size canvasSize, Size worldSize) {
    final usableWidth = max(10.0, canvasSize.width - 28.0);
    final usableHeight = max(10.0, canvasSize.height - 28.0);
    final scale = min(
      usableWidth / worldSize.width,
      usableHeight / worldSize.height,
    );
    final worldPixelSize = Size(
      worldSize.width * scale,
      worldSize.height * scale,
    );
    final offset = Offset(
      (canvasSize.width - worldPixelSize.width) / 2,
      (canvasSize.height - worldPixelSize.height) / 2,
    );
    return WorldViewport(worldSize: worldSize, scale: scale, offset: offset);
  }

  factory WorldViewport.camera({
    required Size canvasSize,
    required Size worldSize,
    required Offset focus,
    required double worldSpanX,
  }) {
    final safeSpanX = worldSpanX.clamp(420.0, worldSize.width);
    final aspect = canvasSize.height / max(1.0, canvasSize.width);
    final spanY = (safeSpanX * aspect).clamp(360.0, worldSize.height);

    final left = (focus.dx - safeSpanX / 2).clamp(
      0.0,
      max(0.0, worldSize.width - safeSpanX),
    );
    final top = (focus.dy - spanY / 2).clamp(
      0.0,
      max(0.0, worldSize.height - spanY),
    );

    final scale = min(canvasSize.width / safeSpanX, canvasSize.height / spanY);
    return WorldViewport(
      worldSize: worldSize,
      scale: scale,
      offset: Offset(-left * scale, -top * scale),
    );
  }

  Offset worldToCanvas(Offset world) =>
      offset + Offset(world.dx * scale, world.dy * scale);

  Offset canvasToWorld(Offset canvas) =>
      Offset((canvas.dx - offset.dx) / scale, (canvas.dy - offset.dy) / scale);

  Offset clampToWorld(Offset world) => Offset(
    world.dx.clamp(0.0, worldSize.width),
    world.dy.clamp(0.0, worldSize.height),
  );
}

class BattleshipGamePage extends StatefulWidget {
  const BattleshipGamePage({super.key});

  @override
  State<BattleshipGamePage> createState() => _BattleshipGamePageState();
}

class _BattleshipGamePageState extends State<BattleshipGamePage>
    with SingleTickerProviderStateMixin {
  static const Size _worldSize = Size(2400, 1600);
  static const double _shipLength = 60;
  static const double _shipWidth = 20;
  static const double _radarRange = 150;
  static const double _maxAcceleration = 240;
  static const double _maxSpeed = 320;
  static const double _missileSpeed = 300;
  static const double _torpedoSpeed = 640;
  static const double _waterDrag = 0.14;
  static const double _mineTriggerRadius = 16;
  static const double _missileCooldownSeconds = 1;
  static const double _mineCooldownSeconds = 3;
  static const double _torpedoCooldownSeconds = 5;

  final Random _random = Random();
  late final Ticker _ticker;

  Duration _lastTick = Duration.zero;
  final List<WorldViewport> _playerViewports = <WorldViewport>[
    const WorldViewport(worldSize: _worldSize, scale: 1, offset: Offset.zero),
    const WorldViewport(worldSize: _worldSize, scale: 1, offset: Offset.zero),
  ];

  late final List<ShipState> _ships;
  final List<Missile> _missiles = <Missile>[];
  final List<Torpedo> _torpedoes = <Torpedo>[];
  final List<Mine> _mines = <Mine>[];
  final List<HitMarker> _hitMarkers = <HitMarker>[];
  final Set<String> _activeCollisions = <String>{};

  final List<bool> _draggingShip = <bool>[false, false];
  final List<String> _playerStatus = <String>['Ready', 'Ready'];
  String _statusText = 'Live battle active';

  @override
  void initState() {
    super.initState();
    _ships = <ShipState>[
      ShipState(id: 0, position: const Offset(420, 420), heading: 0),
      ShipState(id: 1, position: const Offset(1980, 1180), heading: pi),
    ];
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (_lastTick == Duration.zero) {
      _lastTick = elapsed;
      return;
    }
    final dt = ((elapsed - _lastTick).inMicroseconds / 1000000).clamp(
      0.0,
      0.05,
    );
    _lastTick = elapsed;

    _updateShips(dt);
    _updateShipCollisions();
    _updateMissiles(dt);
    _updateTorpedoes(dt);
    _updateMines(dt);
    _updateMarkers(dt);

    if (mounted) {
      setState(() {});
    }
  }

  void _updateShips(double dt) {
    for (final ship in _ships) {
      if (ship.mineCooldown > 0) {
        ship.mineCooldown = max(0, ship.mineCooldown - dt);
      }
      if (ship.torpedoCooldown > 0) {
        ship.torpedoCooldown = max(0, ship.torpedoCooldown - dt);
      }
      if (ship.missileCooldown > 0) {
        ship.missileCooldown = max(0, ship.missileCooldown - dt);
      }
      if (ship.sunk) {
        ship.velocity *= max(0.0, 1.0 - (0.9 * dt));
        ship.position = _clampInsideWorld(ship.position + ship.velocity * dt);
        continue;
      }

      Offset acceleration = Offset.zero;
      if (ship.canMove && ship.dragTarget != null) {
        final direction = ship.dragTarget! - ship.position;
        final distance = direction.distance;
        if (distance > 1) {
          final force = (distance / 180).clamp(0.0, 1.0);
          acceleration = direction / distance * (_maxAcceleration * force);
        }
      }

      if (ship.canMove) {
        ship.velocity += acceleration * dt;
      } else {
        ship.velocity *= max(0.0, 1.0 - (1.25 * dt));
      }

      ship.velocity *= max(0.0, 1.0 - (_waterDrag * dt));
      final speed = ship.velocity.distance;
      if (speed > _maxSpeed) {
        ship.velocity = ship.velocity / speed * _maxSpeed;
      }

      ship.position = _clampInsideWorld(ship.position + ship.velocity * dt);

      final headingTarget = ship.velocity.distance > 6
          ? atan2(ship.velocity.dy, ship.velocity.dx)
          : ship.heading;
      ship.heading = _lerpAngle(
        ship.heading,
        headingTarget,
        min(1.0, dt * 2.4),
      );
    }
  }

  void _updateMissiles(double dt) {
    final List<Missile> toRemove = <Missile>[];
    for (final missile in _missiles) {
      final distance = max(1.0, (missile.target - missile.start).distance);
      missile.progress += (_missileSpeed * dt) / distance;
      if (missile.progress < 1.0) {
        continue;
      }

      final impactPoint = missile.target;

      Mine? hitMine;
      for (final mine in _mines) {
        if ((mine.position - impactPoint).distance <= _mineTriggerRadius) {
          hitMine = mine;
          break;
        }
      }

      if (hitMine != null) {
        _mines.remove(hitMine);
        _hitMarkers.add(
          HitMarker(position: hitMine.position, ttl: 2.0, big: true),
        );
        toRemove.add(missile);
        continue;
      }

      bool shipHit = false;
      for (final ship in _ships) {
        if (ship.id == missile.ownerId || ship.sunk) {
          continue;
        }
        final section = _sectionFromWorldPoint(ship: ship, point: impactPoint);
        if (section != null) {
          _damageShip(
            attackerId: missile.ownerId,
            victim: ship,
            section: section,
            impactPoint: impactPoint,
          );
          shipHit = true;
          break;
        }
      }
      if (!shipHit) {
        _hitMarkers.add(HitMarker(position: impactPoint, ttl: 2.2));
      }
      toRemove.add(missile);
    }
    _missiles.removeWhere(toRemove.contains);
  }

  void _updateTorpedoes(double dt) {
    final List<Torpedo> toRemove = <Torpedo>[];

    for (final torpedo in _torpedoes) {
      torpedo.previousPosition = torpedo.position;
      torpedo.position += torpedo.direction * _torpedoSpeed * dt;

      if (!_isInsideWorld(torpedo.position, margin: 120)) {
        toRemove.add(torpedo);
        continue;
      }

      Mine? hitMine;
      for (final mine in _mines) {
        if (_segmentDistanceToPoint(
              torpedo.previousPosition,
              torpedo.position,
              mine.position,
            ) <=
            _mineTriggerRadius) {
          hitMine = mine;
          break;
        }
      }

      if (hitMine != null) {
        _mines.remove(hitMine);
        _hitMarkers.add(
          HitMarker(position: hitMine.position, ttl: 2.0, big: true),
        );
        toRemove.add(torpedo);
        continue;
      }

      bool hitShip = false;
      for (final ship in _ships) {
        if (ship.id == torpedo.ownerId || ship.sunk) {
          continue;
        }
        final impactPoint = _firstPointOnSegmentInsideShip(
          ship,
          torpedo.previousPosition,
          torpedo.position,
        );
        if (impactPoint == null) {
          continue;
        }
        final section = _sectionFromWorldPoint(ship: ship, point: impactPoint);
        if (section != null) {
          _damageShip(
            attackerId: torpedo.ownerId,
            victim: ship,
            section: section,
            impactPoint: impactPoint,
          );
          hitShip = true;
          break;
        }
      }
      if (hitShip) {
        toRemove.add(torpedo);
      }
    }

    _torpedoes.removeWhere(toRemove.contains);
  }

  void _updateMines(double dt) {
    _mines.removeWhere((mine) {
      mine.ttl -= dt;
      return mine.ttl <= 0;
    });

    final List<Mine> explodedMines = <Mine>[];
    for (final mine in _mines) {
      for (final ship in _ships) {
        if (ship.sunk) {
          continue;
        }
        final hitSection = _sectionFromWorldPoint(
          ship: ship,
          point: mine.position,
        );
        if (hitSection == null) {
          continue;
        }
        explodedMines.add(mine);
        _hitMarkers.add(
          HitMarker(position: mine.position, ttl: 3.0, big: true),
        );
        ship.middleHit = true;
        _sinkShip(victim: ship, attackerId: mine.ownerId);
        break;
      }
    }
    _mines.removeWhere(explodedMines.contains);
  }

  void _updateShipCollisions() {
    final Set<String> nowColliding = <String>{};

    for (var i = 0; i < _ships.length; i++) {
      for (var j = i + 1; j < _ships.length; j++) {
        final a = _ships[i];
        final b = _ships[j];
        if (a.sunk || b.sunk) {
          continue;
        }

        final pairKey = '${a.id}-${b.id}';
        if (!_shipsOverlap(a, b)) {
          continue;
        }
        nowColliding.add(pairKey);

        if (_activeCollisions.contains(pairKey)) {
          continue;
        }

        final rammer = a.velocity.distance >= b.velocity.distance ? a : b;
        final target = identical(rammer, a) ? b : a;

        final rammerImpact = _segmentCenters(rammer).$1;
        final targetImpact = _approximateImpactOnShip(
          target: target,
          other: rammer,
        );
        final targetSection =
            _sectionFromWorldPoint(ship: target, point: targetImpact) ??
            ShipSection.middle;

        _damageShip(
          attackerId: target.id,
          victim: rammer,
          section: ShipSection.front,
          impactPoint: rammerImpact,
        );
        _damageShip(
          attackerId: rammer.id,
          victim: target,
          section: targetSection,
          impactPoint: targetImpact,
        );
        _statusText = 'Collision! P${rammer.id + 1} rammed P${target.id + 1}.';
      }
    }

    _activeCollisions
      ..clear()
      ..addAll(nowColliding);
  }

  void _updateMarkers(double dt) {
    _hitMarkers.removeWhere((marker) {
      marker.ttl -= dt;
      return marker.ttl <= 0;
    });
  }

  void _damageShip({
    required int attackerId,
    required ShipState victim,
    required ShipSection section,
    required Offset impactPoint,
  }) {
    if (victim.sunk) {
      return;
    }

    switch (section) {
      case ShipSection.front:
        victim.frontHit = true;
      case ShipSection.middle:
        victim.middleHit = true;
      case ShipSection.aft:
        victim.aftHit = true;
    }

    _hitMarkers.add(HitMarker(position: impactPoint, ttl: 3.0));

    if (victim.middleHit || (victim.frontHit && victim.aftHit)) {
      _sinkShip(victim: victim, attackerId: attackerId);
    }
  }

  void _sinkShip({required ShipState victim, required int attackerId}) {
    if (victim.sunk) {
      return;
    }

    victim.sunk = true;
    victim.dragTarget = null;
    victim.velocity *= 0.2;
    victim.respawnVersion += 1;
    final version = victim.respawnVersion;

    if (attackerId != victim.id) {
      _ships[attackerId].score += 1;
    }

    _statusText = 'Player ${attackerId + 1} sunk Player ${victim.id + 1}!';
    _playerStatus[victim.id] = 'Sunk';

    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 1800), () {
        if (!mounted || victim.respawnVersion != version) {
          return;
        }
        setState(() {
          _respawn(victim);
        });
      }),
    );
  }

  void _respawn(ShipState ship) {
    ship.sunk = false;
    ship.frontHit = false;
    ship.middleHit = false;
    ship.aftHit = false;
    ship.velocity = Offset.zero;
    ship.dragTarget = null;
    ship.heading = _random.nextDouble() * pi * 2;

    ship.position = _findSafeSpawn(excludingShipId: ship.id);
    ship.missileCooldown = 0;
    ship.torpedoCooldown = 0;
    ship.mineCooldown = 0;
    _playerStatus[ship.id] = 'Ready';
    _statusText = 'Player ${ship.id + 1} respawned.';
  }

  Offset _findSafeSpawn({required int excludingShipId}) {
    for (var i = 0; i < 80; i++) {
      final candidate = Offset(
        120 + _random.nextDouble() * (_worldSize.width - 240),
        120 + _random.nextDouble() * (_worldSize.height - 240),
      );
      bool safe = true;
      for (final ship in _ships) {
        if (ship.id == excludingShipId || ship.sunk) {
          continue;
        }
        if ((candidate - ship.position).distance < _radarRange + 80) {
          safe = false;
          break;
        }
      }
      if (safe) {
        return candidate;
      }
    }
    return Offset(
      120 + _random.nextDouble() * (_worldSize.width - 240),
      120 + _random.nextDouble() * (_worldSize.height - 240),
    );
  }

  Offset _toWorldPoint({
    required int playerId,
    required Offset localPosition,
    required Size paneSize,
    required bool mirrored,
  }) {
    final adjusted = mirrored
        ? Offset(
            paneSize.width - localPosition.dx,
            paneSize.height - localPosition.dy,
          )
        : localPosition;
    final viewport = _playerViewports[playerId];
    return viewport.clampToWorld(viewport.canvasToWorld(adjusted));
  }

  void _setPlayerStatus(int playerId, String text) {
    _playerStatus[playerId] = text;
  }

  void _handleTap(
    int playerId,
    Offset localPosition,
    Size paneSize,
    bool mirrored,
  ) {
    final worldPoint = _toWorldPoint(
      playerId: playerId,
      localPosition: localPosition,
      paneSize: paneSize,
      mirrored: mirrored,
    );
    final player = _ships[playerId];

    if (player.sunk) {
      return;
    }

    final tappedOwnShip =
        _sectionFromWorldPoint(
          ship: player,
          point: worldPoint,
          hitPadding: _shipWidth * 0.6,
        ) !=
        null;
    if (tappedOwnShip) {
      _deployMine(playerId);
      return;
    }

    if (!player.canFireCannon) {
      setState(() {
        _statusText = 'Player ${player.id + 1}: bow cannon destroyed.';
        _setPlayerStatus(player.id, 'Cannon disabled');
      });
      return;
    }

    if (player.missileCooldown > 0) {
      setState(() {
        _statusText =
            'Player ${player.id + 1}: missile reloading ${player.missileCooldown.toStringAsFixed(1)}s.';
        _setPlayerStatus(player.id, 'Missile cooldown');
      });
      return;
    }

    final start = _segmentCenters(player).$1;
    setState(() {
      _missiles.add(
        Missile(ownerId: player.id, start: start, target: worldPoint),
      );
      player.missileCooldown = _missileCooldownSeconds;
      _statusText = 'Player ${player.id + 1}: missile launched.';
      _setPlayerStatus(player.id, 'Cannon fired');
    });
  }

  void _handleLongPress(
    int playerId,
    LongPressStartDetails details,
    Size paneSize,
    bool mirrored,
  ) {
    final worldPoint = _toWorldPoint(
      playerId: playerId,
      localPosition: details.localPosition,
      paneSize: paneSize,
      mirrored: mirrored,
    );
    final player = _ships[playerId];
    if (player.sunk) {
      return;
    }

    if (!player.canFireTorpedo) {
      setState(() {
        _statusText = 'Player ${player.id + 1}: torpedo system offline.';
        _setPlayerStatus(player.id, 'Torpedo offline');
      });
      return;
    }

    if (player.torpedoCooldown > 0) {
      setState(() {
        _statusText =
            'Player ${player.id + 1}: torpedo reloading ${player.torpedoCooldown.toStringAsFixed(1)}s.';
        _setPlayerStatus(player.id, 'Torpedo cooldown');
      });
      return;
    }

    final origin = _segmentCenters(player).$1;
    final direction = (worldPoint - origin).normalized;

    setState(() {
      _torpedoes.add(
        Torpedo(ownerId: player.id, position: origin, direction: direction),
      );
      player.torpedoCooldown = _torpedoCooldownSeconds;
      _statusText = 'Player ${player.id + 1}: torpedo away.';
      _setPlayerStatus(player.id, 'Torpedo fired');
    });
  }

  void _handlePanStart(
    int playerId,
    DragStartDetails details,
    Size paneSize,
    bool mirrored,
  ) {
    final worldPoint = _toWorldPoint(
      playerId: playerId,
      localPosition: details.localPosition,
      paneSize: paneSize,
      mirrored: mirrored,
    );
    final player = _ships[playerId];
    if (!player.canMove) {
      return;
    }

    final onOwnShip =
        _sectionFromWorldPoint(
          ship: player,
          point: worldPoint,
          hitPadding: _shipWidth * 0.7,
        ) !=
        null;
    if (!onOwnShip) {
      return;
    }

    setState(() {
      _draggingShip[playerId] = true;
      player.dragTarget = worldPoint;
      _statusText = 'Player ${player.id + 1}: adjusting throttle vector.';
      _setPlayerStatus(player.id, 'Steering');
    });
  }

  void _handlePanUpdate(
    int playerId,
    DragUpdateDetails details,
    Size paneSize,
    bool mirrored,
  ) {
    if (!_draggingShip[playerId]) {
      return;
    }
    final player = _ships[playerId];
    setState(() {
      player.dragTarget = _toWorldPoint(
        playerId: playerId,
        localPosition: details.localPosition,
        paneSize: paneSize,
        mirrored: mirrored,
      );
    });
  }

  void _handlePanEnd(int playerId, [DragEndDetails? _]) {
    if (!_draggingShip[playerId]) {
      return;
    }
    final player = _ships[playerId];
    setState(() {
      _draggingShip[playerId] = false;
      player.dragTarget = null;
      _statusText = 'Player ${player.id + 1}: helm released.';
      _setPlayerStatus(player.id, 'Cruising');
    });
  }

  void _deployMine(int playerId) {
    final player = _ships[playerId];
    if (player.sunk) {
      return;
    }
    if (player.mineCooldown > 0) {
      setState(() {
        _statusText =
            'Player ${player.id + 1}: mine cooldown ${player.mineCooldown.toStringAsFixed(1)}s.';
        _setPlayerStatus(player.id, 'Mine cooldown');
      });
      return;
    }

    final heading = Offset(cos(player.heading), sin(player.heading));
    final minePos = _clampInsideWorld(
      player.position - heading * (_shipLength * 0.68),
    );

    setState(() {
      _mines.add(Mine(ownerId: player.id, position: minePos, ttl: 30));
      player.mineCooldown = _mineCooldownSeconds;
      _statusText = 'Player ${player.id + 1}: mine deployed.';
      _setPlayerStatus(player.id, 'Mine deployed');
    });
  }

  double _cooldownProgress({required double remaining, required double total}) {
    if (total <= 0) {
      return 1;
    }
    return (1 - (remaining / total)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Offstage(offstage: true, child: Text(_statusText)),
            Expanded(child: _buildPlayerPane(playerId: 1, mirrored: true)),
            _buildInfoArea(),
            Expanded(child: _buildPlayerPane(playerId: 0, mirrored: false)),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoArea() {
    return Container(
      height: 100,
      decoration: const BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(color: Colors.black, width: 2),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: _buildPlayerInfo(playerId: 0)),
          Container(
            width: 150,
            decoration: const BoxDecoration(
              border: Border.symmetric(
                vertical: BorderSide(color: Colors.black, width: 2),
              ),
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '${_ships[0].score} : ${_ships[1].score}',
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Transform.rotate(
              angle: pi,
              child: _buildPlayerInfo(playerId: 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerInfo({required int playerId}) {
    final ship = _ships[playerId];
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'PLAYER ${playerId + 1}: ${_playerStatus[playerId]}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            _buildCooldownBar(
              label: 'Missile',
              remaining: ship.missileCooldown,
              total: _missileCooldownSeconds,
            ),
            const SizedBox(height: 2),
            _buildCooldownBar(
              label: 'Torpedo',
              remaining: ship.torpedoCooldown,
              total: _torpedoCooldownSeconds,
            ),
            const SizedBox(height: 2),
            _buildCooldownBar(
              label: 'Mine',
              remaining: ship.mineCooldown,
              total: _mineCooldownSeconds,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCooldownBar({
    required String label,
    required double remaining,
    required double total,
  }) {
    final progress = _cooldownProgress(remaining: remaining, total: total);
    final ready = remaining <= 0.01;

    return Row(
      children: <Widget>[
        SizedBox(
          width: 54,
          child: Text(
            '$label:',
            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Container(
            height: 6,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black, width: 1),
              color: Colors.white,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: progress,
                child: Container(color: Colors.black),
              ),
            ),
          ),
        ),
        const SizedBox(width: 5),
        SizedBox(
          width: 32,
          child: Text(
            ready ? 'Ready' : '${remaining.toStringAsFixed(1)}s',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 8),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayerPane({required int playerId, required bool mirrored}) {
    final player = _ships[playerId];
    return Container(
      color: Colors.white,
      child: Column(
        children: <Widget>[
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final paneSize = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                final viewport = WorldViewport.camera(
                  canvasSize: paneSize,
                  worldSize: _worldSize,
                  focus: player.position,
                  worldSpanX: _radarRange * 2.8,
                );
                _playerViewports[playerId] = viewport;

                return ClipRect(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => _handleTap(
                      playerId,
                      details.localPosition,
                      paneSize,
                      mirrored,
                    ),
                    onLongPressStart: (details) =>
                        _handleLongPress(playerId, details, paneSize, mirrored),
                    onPanStart: (details) =>
                        _handlePanStart(playerId, details, paneSize, mirrored),
                    onPanUpdate: (details) =>
                        _handlePanUpdate(playerId, details, paneSize, mirrored),
                    onPanEnd: (details) => _handlePanEnd(playerId, details),
                    onPanCancel: () => _handlePanEnd(playerId),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: SketchBattlePainter(
                        viewport: viewport,
                        worldSize: _worldSize,
                        ships: _ships,
                        missiles: _missiles,
                        torpedoes: _torpedoes,
                        mines: _mines,
                        markers: _hitMarkers,
                        activePlayerId: playerId,
                        radarRange: _radarRange,
                        shipLength: _shipLength,
                        shipWidth: _shipWidth,
                        mirrored: mirrored,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  (Offset, Offset, Offset) _segmentCenters(ShipState ship) {
    final headingVec = Offset(cos(ship.heading), sin(ship.heading));
    final segmentSize = _shipLength / 3;
    return (
      ship.position + headingVec * segmentSize,
      ship.position,
      ship.position - headingVec * segmentSize,
    );
  }

  ShipSection? _sectionFromWorldPoint({
    required ShipState ship,
    required Offset point,
    double hitPadding = 0,
  }) {
    if (ship.sunk && (point - ship.position).distance > _shipLength) {
      return null;
    }

    final translated = point - ship.position;
    final cosA = cos(-ship.heading);
    final sinA = sin(-ship.heading);
    final local = Offset(
      translated.dx * cosA - translated.dy * sinA,
      translated.dx * sinA + translated.dy * cosA,
    );

    final halfLength = (_shipLength / 2) + hitPadding;
    final halfWidth = (_shipWidth / 2) + hitPadding;
    if (local.dx.abs() > halfLength || local.dy.abs() > halfWidth) {
      return null;
    }

    final segment = _shipLength / 3;
    if (local.dx >= segment / 2) {
      return ShipSection.front;
    }
    if (local.dx <= -segment / 2) {
      return ShipSection.aft;
    }
    return ShipSection.middle;
  }

  Offset? _firstPointOnSegmentInsideShip(
    ShipState ship,
    Offset from,
    Offset to,
  ) {
    const steps = 14;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final sample = Offset.lerp(from, to, t)!;
      if (_sectionFromWorldPoint(ship: ship, point: sample) != null) {
        return sample;
      }
    }
    return null;
  }

  double _segmentDistanceToPoint(Offset a, Offset b, Offset p) {
    final ab = b - a;
    final abLenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (abLenSq <= 0.00001) {
      return (p - a).distance;
    }
    final t = (((p - a).dx * ab.dx) + ((p - a).dy * ab.dy)) / abLenSq;
    final clampedT = t.clamp(0.0, 1.0);
    final projection = a + ab * clampedT;
    return (p - projection).distance;
  }

  Offset _clampInsideWorld(Offset p) {
    return Offset(
      p.dx.clamp(0.0, _worldSize.width),
      p.dy.clamp(0.0, _worldSize.height),
    );
  }

  bool _isInsideWorld(Offset p, {double margin = 0}) {
    return p.dx >= -margin &&
        p.dy >= -margin &&
        p.dx <= _worldSize.width + margin &&
        p.dy <= _worldSize.height + margin;
  }

  Offset _approximateImpactOnShip({
    required ShipState target,
    required ShipState other,
  }) {
    final towardOther = (other.position - target.position).normalized;
    return _clampInsideWorld(
      target.position + towardOther * (_shipLength * 0.46),
    );
  }

  bool _shipsOverlap(ShipState a, ShipState b) {
    if ((a.position - b.position).distance > _shipLength + _shipWidth) {
      return false;
    }

    final cornersA = _shipCorners(a);
    final cornersB = _shipCorners(b);

    if (cornersA.any(
      (p) => _sectionFromWorldPoint(ship: b, point: p) != null,
    )) {
      return true;
    }
    if (cornersB.any(
      (p) => _sectionFromWorldPoint(ship: a, point: p) != null,
    )) {
      return true;
    }

    for (var i = 0; i < cornersA.length; i++) {
      final a1 = cornersA[i];
      final a2 = cornersA[(i + 1) % cornersA.length];
      for (var j = 0; j < cornersB.length; j++) {
        final b1 = cornersB[j];
        final b2 = cornersB[(j + 1) % cornersB.length];
        if (_segmentsIntersect(a1, a2, b1, b2)) {
          return true;
        }
      }
    }

    return false;
  }

  List<Offset> _shipCorners(ShipState ship) {
    final forward = Offset(cos(ship.heading), sin(ship.heading));
    final side = Offset(-forward.dy, forward.dx);
    final halfLength = _shipLength / 2;
    final halfWidth = _shipWidth / 2;

    return <Offset>[
      ship.position + forward * halfLength + side * halfWidth,
      ship.position + forward * halfLength - side * halfWidth,
      ship.position - forward * halfLength - side * halfWidth,
      ship.position - forward * halfLength + side * halfWidth,
    ];
  }

  bool _segmentsIntersect(Offset p1, Offset p2, Offset q1, Offset q2) {
    final r = p2 - p1;
    final s = q2 - q1;
    final denom = _cross(r, s);
    if (denom.abs() < 0.000001) {
      return false;
    }
    final t = _cross(q1 - p1, s) / denom;
    final u = _cross(q1 - p1, r) / denom;
    return t >= 0 && t <= 1 && u >= 0 && u <= 1;
  }

  double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
}

class SketchBattlePainter extends CustomPainter {
  SketchBattlePainter({
    required this.viewport,
    required this.worldSize,
    required this.ships,
    required this.missiles,
    required this.torpedoes,
    required this.mines,
    required this.markers,
    required this.activePlayerId,
    required this.radarRange,
    required this.shipLength,
    required this.shipWidth,
    required this.mirrored,
  });

  final WorldViewport viewport;
  final Size worldSize;
  final List<ShipState> ships;
  final List<Missile> missiles;
  final List<Torpedo> torpedoes;
  final List<Mine> mines;
  final List<HitMarker> markers;
  final int activePlayerId;
  final double radarRange;
  final double shipLength;
  final double shipWidth;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    if (mirrored) {
      canvas.translate(size.width, size.height);
      canvas.rotate(pi);
    }

    final worldRect = Rect.fromLTWH(
      viewport.offset.dx,
      viewport.offset.dy,
      worldSize.width * viewport.scale,
      worldSize.height * viewport.scale,
    );

    final backPaint = Paint()..color = const Color(0xFFF7F7F7);
    canvas.drawRect(Offset.zero & size, backPaint);

    final paperNoise = Paint()
      ..color = const Color(0x14000000)
      ..strokeWidth = 1;
    for (var i = 0; i < 90; i++) {
      final y = (size.height / 90) * i;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y + _noise(i * 0.87) * 2.4),
        paperNoise,
      );
    }

    final borderPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    _drawSketchRect(canvas, worldRect, borderPaint);

    final gridPaint = Paint()
      ..color = const Color(0x44000000)
      ..strokeWidth = 1;
    const cell = 200.0;
    for (double x = 0; x <= worldSize.width; x += cell) {
      final xPix = viewport.worldToCanvas(Offset(x, 0)).dx;
      _drawDashedLine(
        canvas,
        Offset(xPix, worldRect.top),
        Offset(xPix, worldRect.bottom),
        gridPaint,
      );
    }
    for (double y = 0; y <= worldSize.height; y += cell) {
      final yPix = viewport.worldToCanvas(Offset(0, y)).dy;
      _drawDashedLine(
        canvas,
        Offset(worldRect.left, yPix),
        Offset(worldRect.right, yPix),
        gridPaint,
      );
    }

    for (final marker in markers) {
      final center = viewport.worldToCanvas(marker.position);
      final radius = marker.big ? 18.0 : 10.0;
      final markerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = marker.big ? 2.2 : 1.6
        ..color = Colors.black.withValues(alpha: marker.big ? 0.9 : 0.7);
      canvas.drawCircle(center, radius, markerPaint);
      canvas.drawCircle(center, radius * 0.55, markerPaint);
    }

    final viewer = ships[activePlayerId];
    for (final mine in mines) {
      final visible =
          mine.ownerId == activePlayerId ||
          (viewer.position - mine.position).distance <= radarRange;
      if (!visible) {
        continue;
      }
      final pos = viewport.worldToCanvas(mine.position);
      final minePaint = Paint()
        ..color = Colors.black
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(pos, 9, minePaint);
      canvas.drawLine(
        pos + const Offset(-12, 0),
        pos + const Offset(12, 0),
        minePaint,
      );
      canvas.drawLine(
        pos + const Offset(0, -12),
        pos + const Offset(0, 12),
        minePaint,
      );
    }

    for (final missile in missiles) {
      final current = viewport.worldToCanvas(missile.position);
      final arc = sin(missile.progress * pi) * 22;
      final missilePaint = Paint()
        ..color = Colors.black
        ..style = PaintingStyle.fill;

      canvas.drawCircle(current.translate(0, -arc), 4.8, missilePaint);

      if (missile.ownerId != activePlayerId) {
        final trajPaint = Paint()
          ..color = const Color(0x77000000)
          ..strokeWidth = 1.4;
        _drawDashedLine(
          canvas,
          viewport.worldToCanvas(missile.start),
          viewport.worldToCanvas(missile.target),
          trajPaint,
        );
      }
    }

    for (final torpedo in torpedoes) {
      final a = viewport.worldToCanvas(torpedo.previousPosition);
      final b = viewport.worldToCanvas(torpedo.position);
      final torpPaint = Paint()
        ..color = Colors.black
        ..strokeWidth = 2.3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(a, b, torpPaint);
    }

    for (final ship in ships) {
      _drawShip(canvas, ship);
    }

    final radarPaint = Paint()
      ..color = const Color(0x11000099)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(
      viewport.worldToCanvas(viewer.position),
      radarRange * viewport.scale,
      radarPaint,
    );

    final bearingPaint = Paint()..color = const Color(0xFFD00000);
    for (final ship in ships) {
      if (ship.id == activePlayerId || ship.sunk) {
        continue;
      }
      final direction = (ship.position - viewer.position).normalized;
      final markerWorld = viewer.position + direction * radarRange;
      final markerCanvas = viewport.worldToCanvas(markerWorld);
      canvas.drawCircle(markerCanvas, 4.5, bearingPaint);
    }

    if (viewer.dragTarget != null && !viewer.sunk) {
      final dragPaint = Paint()
        ..color = Colors.black
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      final from = viewport.worldToCanvas(viewer.position);
      final to = viewport.worldToCanvas(viewer.dragTarget!);
      canvas.drawLine(from, to, dragPaint);
      canvas.drawCircle(to, 5, dragPaint..style = PaintingStyle.fill);
    }

    canvas.restore();
  }

  void _drawShip(Canvas canvas, ShipState ship) {
    final center = viewport.worldToCanvas(ship.position);
    final w = shipLength * viewport.scale;
    final h = shipWidth * viewport.scale;
    final segment = w / 3;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(ship.heading);

    final hullRect = Rect.fromCenter(center: Offset.zero, width: w, height: h);
    final hullFill = Paint()
      ..style = PaintingStyle.fill
      ..color = ship.sunk ? const Color(0x33000000) : const Color(0x0C000000);
    canvas.drawRRect(
      RRect.fromRectAndRadius(hullRect, Radius.circular(h * 0.42)),
      hullFill,
    );

    final sketch = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black;
    _drawSketchRRect(
      canvas,
      RRect.fromRectAndRadius(hullRect, Radius.circular(h * 0.42)),
      sketch,
    );

    final divPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(-segment / 2, -h / 2),
      Offset(-segment / 2, h / 2),
      divPaint,
    );
    canvas.drawLine(
      Offset(segment / 2, -h / 2),
      Offset(segment / 2, h / 2),
      divPaint,
    );

    if (ship.aftHit) {
      final aftRect = Rect.fromLTWH(-w / 2, -h / 2, segment, h);
      canvas.drawRect(aftRect, Paint()..color = const Color(0x60000000));
    }
    if (ship.middleHit) {
      final midRect = Rect.fromLTWH(-segment / 2, -h / 2, segment, h);
      canvas.drawRect(midRect, Paint()..color = const Color(0x70000000));
    }
    if (ship.frontHit) {
      final frontRect = Rect.fromLTWH(segment / 2, -h / 2, segment, h);
      canvas.drawRect(frontRect, Paint()..color = const Color(0x60000000));
    }

    final cannonPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(segment * 0.6, 0),
      Offset(segment * 1.2, 0),
      cannonPaint,
    );

    final enginePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(-w * 0.48, 0), width: 12, height: h * 0.5),
      -pi / 2,
      pi,
      false,
      enginePaint,
    );

    canvas.restore();

    final label = TextPainter(
      text: TextSpan(
        text: ship.sunk ? 'P${ship.id + 1} SUNK' : 'P${ship.id + 1}',
        style: const TextStyle(
          color: Colors.black,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, center + const Offset(-18, -34));
  }

  void _drawSketchRect(Canvas canvas, Rect rect, Paint paint) {
    final jitter1 = Offset(
      _noise(rect.left * 0.01) * 1.2,
      _noise(rect.top * 0.01) * 1.2,
    );
    final jitter2 = Offset(
      _noise(rect.right * 0.01) * 0.9,
      _noise(rect.bottom * 0.01) * 0.9,
    );
    canvas.drawRect(rect.shift(jitter1), paint);
    canvas.drawRect(rect.shift(jitter2), paint);
  }

  void _drawSketchRRect(Canvas canvas, RRect rRect, Paint paint) {
    final j1 = Offset(
      _noise(rRect.left * 0.013) * 0.9,
      _noise(rRect.top * 0.013) * 0.9,
    );
    final j2 = Offset(
      _noise(rRect.right * 0.011) * 0.8,
      _noise(rRect.bottom * 0.011) * 0.8,
    );
    canvas.drawRRect(rRect.shift(j1), paint);
    canvas.drawRRect(rRect.shift(j2), paint);
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    final delta = end - start;
    final length = delta.distance;
    if (length <= 0.1) {
      return;
    }
    final unit = delta / length;
    const dash = 9.0;
    const gap = 7.0;

    double cursor = 0;
    while (cursor < length) {
      final from = start + unit * cursor;
      final to = start + unit * min(cursor + dash, length);
      canvas.drawLine(from, to, paint);
      cursor += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant SketchBattlePainter oldDelegate) => true;
}

double _noise(double x) => sin(x * 19.134 + 0.37) * 0.5 + cos(x * 7.17) * 0.3;

double _lerpAngle(double current, double target, double t) {
  var delta = (target - current + pi) % (2 * pi) - pi;
  if (delta < -pi) {
    delta += 2 * pi;
  }
  return current + delta * t;
}

extension OffsetX on Offset {
  Offset get normalized {
    final d = distance;
    if (d <= 0.000001) {
      return const Offset(1, 0);
    }
    return this / d;
  }
}
