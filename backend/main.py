from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles


BASE_DIR = Path(__file__).resolve().parent.parent
FRONTEND_DIR = BASE_DIR / "frontend"

CITIES = {"广州", "深圳", "佛山", "东莞"}
MODES = ("高铁", "长途汽车", "网约车")

ROUTES: dict[frozenset[str], dict[str, tuple[int, int]]] = {
    frozenset(("广州", "深圳")): {
        "高铁": (80, 60),
        "长途汽车": (65, 150),
        "网约车": (360, 120),
    },
    frozenset(("广州", "佛山")): {
        "高铁": (25, 25),
        "长途汽车": (18, 70),
        "网约车": (110, 60),
    },
    frozenset(("广州", "东莞")): {
        "高铁": (50, 45),
        "长途汽车": (40, 110),
        "网约车": (220, 95),
    },
    frozenset(("深圳", "佛山")): {
        "高铁": (90, 75),
        "长途汽车": (75, 180),
        "网约车": (420, 150),
    },
    frozenset(("深圳", "东莞")): {
        "高铁": (35, 30),
        "长途汽车": (28, 75),
        "网约车": (150, 65),
    },
    frozenset(("佛山", "东莞")): {
        "高铁": (55, 55),
        "长途汽车": (45, 120),
        "网约车": (240, 100),
    },
}

app = FastAPI(title="华南出行成本迷你计算器")
app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")


def _validate_request(payload: dict[str, Any]) -> tuple[str, str, int]:
    origin = payload.get("origin")
    destination = payload.get("destination")
    passengers = payload.get("passengers")

    if not isinstance(origin, str) or origin not in CITIES:
        raise HTTPException(status_code=400, detail="不支持的出发城市")
    if not isinstance(destination, str) or destination not in CITIES:
        raise HTTPException(status_code=400, detail="不支持的目的城市")
    if origin == destination:
        raise HTTPException(status_code=400, detail="出发城市和目的城市不能相同")
    if not isinstance(passengers, int) or isinstance(passengers, bool):
        raise HTTPException(status_code=400, detail="出行人数必须是整数")
    if passengers < 1:
        raise HTTPException(status_code=400, detail="出行人数不能小于 1")
    if passengers > 4:
        raise HTTPException(status_code=400, detail="出行人数不能大于 4")

    return origin, destination, passengers


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/", include_in_schema=False)
def index() -> FileResponse:
    return FileResponse(FRONTEND_DIR / "index.html")


@app.post("/api/compare")
def compare(payload: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    origin, destination, passengers = _validate_request(payload)
    route = ROUTES[frozenset((origin, destination))]

    options: list[dict[str, Any]] = []
    for mode in MODES:
        base_cost, duration = route[mode]
        total_cost = base_cost if mode == "网约车" else base_cost * passengers
        options.append(
            {
                "mode": mode,
                "total_cost": round(float(total_cost), 2),
                "per_person_cost": round(total_cost / passengers, 2),
                "duration_minutes": duration,
                "tag": "",
            }
        )

    cheapest_mode = min(options, key=lambda option: option["total_cost"])["mode"]
    fastest_mode = min(options, key=lambda option: option["duration_minutes"])["mode"]

    for option in options:
        if option["mode"] == cheapest_mode:
            option["tag"] = "最省钱"
        elif option["mode"] == fastest_mode:
            option["tag"] = "最快"
        elif option["mode"] == "网约车" and passengers >= 3:
            option["tag"] = "多人更划算"

    return {"options": options}
