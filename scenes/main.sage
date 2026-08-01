{
  "lighting": {
    "ambientColor": { "x": 0.42, "y": 0.5, "z": 0.62 },
    "ambientGround": { "x": 0.22, "y": 0.2, "z": 0.17 },
    "ambientSky": { "x": 0.52, "y": 0.68, "z": 0.92 },
    "ambientStrength": 0.38,
    "fog": {
      "color": { "x": 0.62, "y": 0.72, "z": 0.86 },
      "enabled": true,
      "end": 108.0,
      "start": 34.0
    },
    "pointLights": [],
    "skybox": {
      "cubemapDir": "",
      "enabled": true,
      "horizon": { "x": 0.74, "y": 0.85, "z": 0.95 },
      "intensity": 1.0,
      "rotation": 0.0,
      "top": { "x": 0.28, "y": 0.5, "z": 0.86 }
    },
    "spotLights": [],
    "sun": {
      "color": { "x": 1.0, "y": 0.96, "z": 0.86 },
      "direction": { "x": -0.45, "y": -0.85, "z": -0.35 },
      "intensity": 1.15
    }
  },
  "name": "The Boat",
  "objects": [
    {
      "color": { "x": 1.0, "y": 1.0, "z": 1.0 },
      "id": 1,
      "mesh": { "path": "", "type": "none" },
      "name": "World",
      "position": { "x": 0.0, "y": 0.0, "z": 0.0 },
      "rotation": { "x": 0.0, "y": 0.0, "z": 0.0 },
      "scale": { "x": 1.0, "y": 1.0, "z": 1.0 },
      "script": "assets/scripts/game.lua"
    },
    {
      "color": { "x": 1.0, "y": 1.0, "z": 1.0 },
      "id": 2,
      "mesh": { "path": "", "type": "none" },
      "name": "Player",
      "position": { "x": 48.5, "y": 16.0, "z": 64.5 },
      "rotation": { "x": 0.0, "y": 180.0, "z": 0.0 },
      "scale": { "x": 1.0, "y": 1.0, "z": 1.0 }
    },
    {
      "camera": {
        "far": 240.0,
        "fov": 78.0,
        "near": 0.08,
        "orthoHeight": 10.0,
        "primary": true,
        "projection": "perspective"
      },
      "color": { "x": 1.0, "y": 1.0, "z": 1.0 },
      "id": 3,
      "mesh": { "path": "", "type": "none" },
      "name": "Player Camera",
      "parent": 2,
      "position": { "x": 0.0, "y": 1.62, "z": 0.0 },
      "rotation": { "x": -8.0, "y": 0.0, "z": 0.0 },
      "scale": { "x": 1.0, "y": 1.0, "z": 1.0 }
    }
  ],
  "sage_scene_version": 1
}
