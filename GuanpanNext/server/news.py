"""新闻标题抓取（Google News RSS）。

NAS 是后台研究员：只负责把公开新闻标题带到手机端，由手机端规则引擎
（NextNewsImpactEngine）判断与持仓的关系。NAS 不生成任何 AI 结论。
"""
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from xml.etree import ElementTree


def fetch_headlines(code, name, opener=urlopen):
    """Fetch a small linked headline set from Google News RSS; failures remain explicit."""
    query = urlencode({"q": f'"{name}" ETF OR {code}', "hl": "zh-CN", "gl": "CN", "ceid": "CN:zh-Hans"})
    url = "https://news.google.com/rss/search?" + query
    request = Request(url, headers={"User-Agent": "GuanpanAdvisor/3.6 news"})
    try:
        with opener(request, timeout=8) as response:
            if response.status != 200:
                raise OSError("news source unavailable")
            root = ElementTree.fromstring(response.read(1_000_000))
        rows = []
        cutoff = datetime.now(timezone.utc) - timedelta(days=30)
        for item in root.findall("./channel/item"):
            pub_date = item.findtext("pubDate")
            try:
                parsed_date = parsedate_to_datetime(pub_date).astimezone(timezone.utc)
                if parsed_date < cutoff or parsed_date > datetime.now(timezone.utc) + timedelta(hours=2):
                    continue
            except (TypeError, ValueError, OverflowError):
                continue
            rows.append({"title": (item.findtext("title") or "")[:300], "url": item.findtext("link") or "",
                         "publishedAt": pub_date, "source": item.findtext("source")})
            if len(rows) >= 8:
                break
        return {"state": "ok" if rows else "empty", "provider": "Google News RSS", "items": rows}
    except Exception as error:
        return {"state": "unavailable", "provider": "Google News RSS", "items": [], "error": type(error).__name__}
