from dataclasses import asdict, dataclass, field


@dataclass
class Segment:
    seg_id: str
    file_id: str
    kind: str
    modality: str          # "text" | "image" | "audio"
    anchor: dict = field(default_factory=dict)
    text: str = ""         # extracted text, OCR or transcript (used by keyword search)
    media: str = ""        # file path for image/audio segments

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "Segment":
        return cls(**d)


def make_seg_id(file_id: str, n: int) -> str:
    return f"{file_id}:{n}"
