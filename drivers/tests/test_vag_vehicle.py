"""VAG EU Data Act driver: identity, zip decode, freshness, 401."""
from pathlib import Path
import io
import json
import struct
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

NO_SOC = json.dumps({"vin": "WVWZZZTESTVIN0001", "Data": [
    {"key": "9da735bb-c5d5-39f8-bf53-0fa2a367aa8f", "dataFieldName": "charging_state",
     "value": "charging", "timestampUtc": "2026-09-26T07:15:00Z"},
]})


def _zip(method: int, text: str = DATASET) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=method) as zf:
        zf.writestr("dataset.json", text)
    return buf.getvalue()


class _WriteOnly(io.RawIOBase):
    """A stream zipfile cannot seek back into, like a streamed HTTP body."""

    def __init__(self) -> None:
        self.data = bytearray()

    def writable(self) -> bool:
        return True

    def write(self, b) -> int:
        self.data += b
        return len(b)


def _zip_streamed() -> bytes:
    sink = _WriteOnly()
    with zipfile.ZipFile(sink, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("dataset.json", DATASET)
    blob = bytes(sink.data)
    flags, = struct.unpack_from("<H", blob, 6)
    comp_size, = struct.unpack_from("<I", blob, 18)
    assert flags & 0x08 and comp_size == 0, "fixture must carry its sizes in a data descriptor"
    return blob


def _zip_oversized() -> bytes:
    # About 5 MB of JSON that deflates to a few kB: over the driver's 2 MiB cap.
    text = json.dumps({"vin": "WVWZZZTESTVIN0001", "Data": [], "pad": " " * 5_000_000})
    return _zip(zipfile.ZIP_DEFLATED, text)


def _zip_large() -> bytes:
    # About 360 kB of data points: enough that unzipping flushes chunks.
    rows = [
        {"key": "00000000-0000-3000-8000-%012d" % i, "dataFieldName": "mileage",
         "value": str(i), "timestampUtc": "2026-09-26T07:00:00Z"}
        for i in range(3000)
    ]
    rows.append({"key": "162c2a75-edf4-3990-b8ed-7c600b3dbc40",
                 "dataFieldName": "battery_level_HV.value", "value": "71",
                 "timestampUtc": "2026-09-26T07:00:00Z"})
    return _zip(zipfile.ZIP_DEFLATED, json.dumps({"vin": "WVWZZZTESTVIN0001", "Data": rows}))


def test_vag_vehicle_dataset_and_freshness(tmp_path: Path) -> None:
    fixtures = {
        "stored": _zip(zipfile.ZIP_STORED),
        "deflated": _zip(zipfile.ZIP_DEFLATED),
        "streamed": _zip_streamed(),
        "oversized": _zip_oversized(),
        "nosoc": _zip(zipfile.ZIP_DEFLATED, NO_SOC),
        "large": _zip_large(),
    }
    paths = []
    for name, blob in fixtures.items():
        path = tmp_path / f"{name}.zip"
        path.write_bytes(blob)
        paths.append(str(path))
    result = subprocess.run(
        [str(ROOT / "lua55"), "drivers/tests/lua_harness/test_vag_vehicle.lua", *paths],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
