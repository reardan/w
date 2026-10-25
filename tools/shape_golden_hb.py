#!/usr/bin/env python3
"""Regenerate tests/data/shape_golden.txt from HarfBuzz (uharfbuzz).

    pip install uharfbuzz
    python3 tools/shape_golden_hb.py > tests/data/shape_golden.txt

Each font section lists text lines with HarfBuzz's output in the
tools/shape_dump.w format; tests/ttf_shape_test.w shapes the same lines
with lib/ttf_shape.w and requires identical output. The text for each
font is in SECTIONS below; add a line there, rerun, and commit both.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shape_compare_hb import harfbuzz  # noqa: E402

SECTIONS = [
    ("tools/ui/LiberationSans-Regular.ttf", [
        "AVATAR Wolf To. Ty, LT",
        "é ễ ậ ǖ q̣̇ ø̈",
        "é ä́ ñ",
        "Тест Ўў Їжак",
        "Ελληνικά ά ῷ",
        "עִבְרִית שָׁלוֹם בְּרֵאשִׁית",
        "(a[b]{c}) «x» ‹y›",
        "a‍b‌c x︀y ‎z‏",
        "مرحبا English 123",
        "नमस्ते",
    ]),
    ("tests/data/fonts/NotoSans-subset.ttf", [
        "office fluffy affine ffi ffl fj",
        "fi fl ffi ffl ff",
        "Ünïcödé façade naïve résumé",
        "e̊ q̣̇ a͜b x̧̌",
        "AVATAR Wolf To. Ty, LT",
    ]),
    ("tests/data/fonts/NotoSansArabic-subset.ttf", [
        "مرحبا بالعالم",
        "السلام عليكم ورحمة الله وبركاته",
        "لا إله إلا الله ﻻ لأ لآ",
        "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ",
        "١٢٣ ٤٥٦",
        "فارسی: کتاب‌ها گچ پژوهش",
        "اردو: پاکستان ہے",
        "ـبـ ـ ب‍ ‍ب",
    ]),
    ("tests/data/fonts/NotoSansDevanagari-subset.ttf", [
        "नमस्ते दुनिया",
        "हिन्दी भाषा का इतिहास बहुत पुराना है।",
        "संस्कृत क्षत्रिय श्री",
        "क्षत्रिय ज्ञान श्री त्र द्ध द्व र्क र्कि कि कृ प्र्य",
        "अर्थ धर्म कर्म पूर्ण आर्य सूर्य",
    ]),
    ("tests/data/fonts/NotoSansBengali-subset.ttf", [
        "বাংলা ভাষা আমার মাতৃভাষা",
        "কর্ম ধর্ম সূর্য র্কি ক্ষ জ্ঞ",
        "কো কৌ কি কে কৈ ত্র প্র ক্র ক্য",
        "শ্রী স্ত্র ন্দ্র ৎ ক্\u200d ্ক",
    ]),
    ("tests/data/fonts/NotoSansGurmukhi-subset.ttf", [
        "ਪੰਜਾਬੀ ਭਾਸ਼ਾ ਗੁਰਮੁਖੀ",
        "ਕਿ ਕੀ ਕੇ ਕੈ ਕੋ ਕੌ ਕੁ ਕੂ ਕੰ ਕਂ ਕੱ",
        "ਪ੍ਰ ਕ੍ਰ ਸ੍ਵ ਦ੍ਹ ਖ਼ ਗ਼ ਜ਼ ਫ਼",
        "ਕਿੰ ਸਿੱਖ ਧਰਮ ੍ਕ",
    ]),
    ("tests/data/fonts/NotoSansGujarati-subset.ttf", [
        "ગુજરાતી ભાષા",
        "કર્મ ધર્મ સૂર્ય ર્કિ ક્ષ જ્ઞ શ્રી",
        "કિ કી કે કૈ કો કૌ ત્ર પ્ર ક્ર દ્ધ",
        "સ્ત્રી ન્દ્ર ક્\u200d ્ક",
    ]),
    ("tests/data/fonts/NotoSansOriya-subset.ttf", [
        "ଓଡ଼ିଆ ଭାଷା",
        "କର୍ମ ଧର୍ମ ସୂର୍ଯ୍ୟ ର୍କି କ୍ଷ ଜ୍ଞ",
        "କୋ କୌ କି କେ କୈ ତ୍ର ପ୍ର କ୍ର କ୍ୟ",
        "ଶ୍ରୀ ସ୍ତ୍ର ନ୍ଦ୍ର ୍କ",
    ]),
    ("tests/data/fonts/NotoSansTamil-subset.ttf", [
        "தமிழ் மொழி",
        "கொ கோ கௌ கெ கே கை கி கீ கு கூ",
        "க்ஷ ஸ்ரீ ஶ்ரீ க்ஷா த்தி",
        "நன்றி வணக்கம் ்க",
    ]),
    ("tests/data/fonts/NotoSansTelugu-subset.ttf", [
        "తెలుగు భాష",
        "కర్మ ధర్మ సూర్య ర్కి క్ష జ్ఞ శ్రీ",
        "కి కీ కె కే కై కొ కో కౌ కృ త్ర ప్ర క్ర",
        "స్త్రీ న్ద్ర క్క ర్\u200dక ్క",
    ]),
    ("tests/data/fonts/NotoSansKannada-subset.ttf", [
        "ಕನ್ನಡ ಭಾಷೆ",
        "ಕರ್ಮ ಧರ್ಮ ಸೂರ್ಯ ರ್ಕಿ ಕ್ಷ ಜ್ಞ ಶ್ರೀ",
        "ಕಿ ಕೀ ಕೆ ಕೇ ಕೈ ಕೊ ಕೋ ಕೌ ಕೃ ತ್ರ ಪ್ರ ಕ್ರ",
        "ಸ್ತ್ರೀ ನ್ದ್ರ ಕ್ಕ ರ್ಷೋ್ ್ಕ",
    ]),
    ("tests/data/fonts/NotoSansMalayalam-subset.ttf", [
        "മലയാളം ഭാഷ",
        "കർമ്മം ധർമ്മം സൂര്യൻ ക്ഷ ജ്ഞ ശ്രീ",
        "കൊ കോ കൌ കെ കേ കൈ കി കീ കു കൂ കൃ",
        "ക്ര പ്ര ക്യ ക്വ ന്റ ൽ ൾ ്ക",
    ]),
    ("tests/data/fonts/NotoSansHebrew-subset.ttf", [
        "עִבְרִית שָׁלוֹם בְּרֵאשִׁית",
        "שָׁלוֹם עוֹלָם בְּרֵאשִׁית בָּרָא",
        "תּוֹרָה וּמִצְוֹת",
    ]),
    ("tests/data/fonts/NotoSansThai-subset.ttf", [
        "สวัสดีครับ ภาษาไทย น้ำ ที่",
    ]),
    # Hidden tables reach the fallbacks: legacy kern and mark placement
    # without GPOS, presentation forms without GSUB, Hebrew presentation
    # compositions without GPOS mark, and Indic reordering without GSUB.
    ("tools/ui/LiberationSans-Regular.ttf!-GPOS", [
        "AVATAR Wolf To. Ty, LT",
        "é ễ ậ ǖ q̣̇ ø̈",
        "e̊ q̣̇ a͜b x̧̌",
        "עִבְרִית שָׁלוֹם בְּרֵאשִׁית",
        "a\u200db\u200cc x\ufe00y \u200ez\u200f",
    ]),
    ("tools/ui/LiberationSans-Regular.ttf!-GPOS!-GSUB!-GDEF", [
        "é ễ ậ ǖ q̣̇ ø̈",
        "Ελληνικά ά ῷ",
    ]),
    ("tests/data/fonts/NotoSansArabic-subset.ttf!-GSUB", [
        "مرحبا بالعالم",
        "لا إله إلا الله ﻻ لأ لآ",
        "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ",
    ]),
    ("tests/data/fonts/NotoSansHebrew-subset.ttf!-GPOS", [
        "שָׁלוֹם עוֹלָם בְּרֵאשִׁית בָּרָא",
        "תּוֹרָה וּמִצְוֹת",
    ]),
    ("tests/data/fonts/NotoSansDevanagari-subset.ttf!-GSUB", [
        "हिन्दी भाषा का इतिहास बहुत पुराना है।",
        "क्षत्रिय ज्ञान श्री त्र द्ध द्व र्क र्कि कि कृ प्र्य",
    ]),
]


def main():
    print("# HarfBuzz output for tests/ttf_shape_test.w; regenerate with")
    print("# python3 tools/shape_golden_hb.py > tests/data/shape_golden.txt")
    print("# '@font' starts a section; other lines are text<TAB>expected.")
    for font, lines in SECTIONS:
        print("@" + font)
        for text, expected in zip(lines, harfbuzz(font, lines)):
            print(text + "\t" + expected)


if __name__ == "__main__":
    main()
