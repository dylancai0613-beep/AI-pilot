from fastapi.testclient import TestClient

from backend.main import app


client = TestClient(app)


def compare(origin: str, destination: str, passengers: object):
    return client.post(
        "/api/compare",
        json={
            "origin": origin,
            "destination": destination,
            "passengers": passengers,
        },
    )


def test_health() -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_homepage_contains_required_form_elements() -> None:
    response = client.get("/")

    assert response.status_code == 200
    assert 'id="origin"' in response.text
    assert 'id="destination"' in response.text
    assert 'id="passengers"' in response.text
    assert 'id="submit-button"' in response.text
    assert 'id="results"' in response.text
    assert 'id="error-message"' in response.text


def test_guangzhou_to_shenzhen_for_two_passengers() -> None:
    response = compare("广州", "深圳", 2)

    assert response.status_code == 200
    assert response.json() == {
        "options": [
            {
                "mode": "高铁",
                "total_cost": 160.0,
                "per_person_cost": 80.0,
                "duration_minutes": 60,
                "tag": "最快",
            },
            {
                "mode": "长途汽车",
                "total_cost": 130.0,
                "per_person_cost": 65.0,
                "duration_minutes": 150,
                "tag": "最省钱",
            },
            {
                "mode": "网约车",
                "total_cost": 360.0,
                "per_person_cost": 180.0,
                "duration_minutes": 120,
                "tag": "",
            },
        ]
    }


def test_reverse_route_uses_same_data() -> None:
    forward = compare("深圳", "东莞", 3)
    reverse = compare("东莞", "深圳", 3)

    assert forward.status_code == 200
    assert reverse.status_code == 200
    assert forward.json() == reverse.json()
    assert forward.json()["options"][2]["tag"] == "多人更划算"


def test_all_distinct_city_pairs_are_supported() -> None:
    cities = ("广州", "深圳", "佛山", "东莞")

    for origin in cities:
        for destination in cities:
            if origin != destination:
                assert compare(origin, destination, 1).status_code == 200


def test_same_origin_and_destination_returns_400() -> None:
    response = compare("广州", "广州", 2)

    assert response.status_code == 400
    assert response.json() == {"detail": "出发城市和目的城市不能相同"}


def test_passengers_above_four_returns_400() -> None:
    response = compare("广州", "深圳", 5)

    assert response.status_code == 400
    assert response.json() == {"detail": "出行人数不能大于 4"}


def test_invalid_business_inputs_return_400() -> None:
    cases = [
        ("珠海", "深圳", 2, "不支持的出发城市"),
        ("广州", "珠海", 2, "不支持的目的城市"),
        ("广州", "深圳", 0, "出行人数不能小于 1"),
        ("广州", "深圳", 2.5, "出行人数必须是整数"),
        ("广州", "深圳", "2", "出行人数必须是整数"),
    ]

    for origin, destination, passengers, detail in cases:
        response = compare(origin, destination, passengers)
        assert response.status_code == 400
        assert response.json() == {"detail": detail}


def test_ride_hailing_total_is_fixed_and_per_person_is_rounded() -> None:
    one_passenger = compare("广州", "佛山", 1).json()["options"][2]
    three_passengers = compare("广州", "佛山", 3).json()["options"][2]

    assert one_passenger["total_cost"] == 110.0
    assert three_passengers["total_cost"] == 110.0
    assert three_passengers["per_person_cost"] == 36.67
    assert three_passengers["tag"] == "多人更划算"
