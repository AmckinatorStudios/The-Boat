{
  "lighting": {
    "ambientColor": {
      "x": 0.42,
      "y": 0.5,
      "z": 0.62
    },
    "ambientGround": {
      "x": 0.22,
      "y": 0.2,
      "z": 0.17
    },
    "ambientSky": {
      "x": 0.52,
      "y": 0.68,
      "z": 0.92
    },
    "ambientStrength": 0.42,
    "fog": {
      "color": {
        "x": 0.66,
        "y": 0.8,
        "z": 0.93
      },
      "enabled": true,
      "end": 48.0,
      "start": 14.0
    },
    "pointLights": [],
    "skybox": {
      "cubemapDir": "",
      "enabled": true,
      "horizon": {
        "x": 0.7,
        "y": 0.84,
        "z": 0.95
      },
      "intensity": 1.0,
      "rotation": 0.0,
      "top": {
        "x": 0.24,
        "y": 0.46,
        "z": 0.86
      }
    },
    "spotLights": [],
    "sun": {
      "color": {
        "x": 1.0,
        "y": 0.96,
        "z": 0.88
      },
      "direction": {
        "x": -0.5,
        "y": -0.8,
        "z": -0.4
      },
      "intensity": 1.2
    }
  },
  "name": "The Boat",
  "objects": [
    {
      "color": {
        "x": 1.0,
        "y": 1.0,
        "z": 1.0
      },
      "id": 1,
      "mesh": {
        "path": "",
        "type": "none"
      },
      "name": "World",
      "position": {
        "x": 0.0,
        "y": 0.0,
        "z": 0.0
      },
      "rotation": {
        "x": 0.0,
        "y": 0.0,
        "z": 0.0
      },
      "scale": {
        "x": 1.0,
        "y": 1.0,
        "z": 1.0
      },
      "script": "assets/scripts/game.lua"
    },
    {
      "color": {
        "x": 1.0,
        "y": 1.0,
        "z": 1.0
      },
      "id": 2,
      "mesh": {
        "path": "",
        "type": "none"
      },
      "name": "Player",
      "position": {
        "x": 0.0,
        "y": 1.55,
        "z": -2.0
      },
      "rotation": {
        "x": 0.0,
        "y": 0.0,
        "z": 0.0
      },
      "scale": {
        "x": 1.0,
        "y": 1.0,
        "z": 1.0
      }
    },
    {
      "camera": {
        "far": 260.0,
        "fov": 74.0,
        "near": 0.08,
        "orthoHeight": 10.0,
        "primary": true,
        "projection": "perspective"
      },
      "color": {
        "x": 1.0,
        "y": 1.0,
        "z": 1.0
      },
      "id": 3,
      "mesh": {
        "path": "",
        "type": "none"
      },
      "name": "Player Camera",
      "parent": 2,
      "position": {
        "x": 0.0,
        "y": 1.6,
        "z": 0.0
      },
      "rotation": {
        "x": -6.0,
        "y": 0.0,
        "z": 0.0
      },
      "scale": {
        "x": 1.0,
        "y": 1.0,
        "z": 1.0
      }
    }
  ],
  "sage_scene_version": 1
}
