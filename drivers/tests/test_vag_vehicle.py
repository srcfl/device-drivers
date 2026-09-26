"""VAG EU Data Act driver: identity, zip decode, freshness, 401."""
from pathlib import Path
import io
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[2]

DATASET = """{"vin":"WVWZZZTESTVIN0001","Data":[
  {"key":"162c2a75-edf4-3990-b8ed-7c600b3dbc40","dataFieldName":"battery_level_HV.value","value":"63","timestampUtc":"2026-09-26T07:00:00Z"},
  {"key":"76acaa98-37ef-3466-b013-21c77ed343ae","dataFieldName":"settings.target_soc","value":"80","timestampUtc":"2026-09-26T07:00:00Z"},
  {"key":"9da735bb-c5d5-39f8-bf53-0fa2a367aa8f","dataFieldName":"charging_state","value":"charging","timestampUtc":"2026-09-26T07:00:00Z"},
  {"key":"c111830c-f959-30d2-859a-ea996190d864","dataFieldName":"plug_state","value":"connected","timestampUtc":"2026-09-26T07:00:00Z"},
  {"key":"cf28f7d9-6201-30b8-82e5-a461968d30dc","dataFieldName":"remaining_charging_time","value":"42","timestampUtc":"2026-09-26T07:00:00Z"}
]}"""


def _zip(method: int) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=method) as zf:
        zf.writestr("dataset.json", DATASET)
    return buf.getvalue()


def test_vag_vehicle_dataset_and_freshness(tmp_path: Path) -> None:
    stored = tmp_path / "stored.zip"
    deflated = tmp_path / "deflated.zip"
    stored.write_bytes(_zip(zipfile.ZIP_STORED))
    deflated.write_bytes(_zip(zipfile.ZIP_DEFLATED))
    result = subprocess.run(
        [
            str(ROOT / "lua55"),
            "drivers/tests/lua_harness/test_vag_vehicle.lua",
            str(stored),
            str(deflated),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
