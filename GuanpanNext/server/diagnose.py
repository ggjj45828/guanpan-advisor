"""NAS 出网自检：把「服务能打开、行情全 502/503」的三种环境原因一次分开。

手机和网页只看得到 502/503，看不出到底卡在哪。这里逐项探测，最后给一句结论：

1. 没有外网出口 —— 连公网 registry 也不通。Z4Pro 当初连 Docker Registry 都要换
   国内镜像源，同一类问题很可能也挡住了 qt.gtimg.cn / 东财。
2. 系统时钟不准 —— Z4Pro 断电后 RTC 复位很常见。时钟错到证书有效期之外，
   HTTPS 会在**握手阶段**就失败，两个源同时全挂，症状和「没外网」一模一样。
   这里拿上游响应头 `Date` 反推偏差，不用相信本机时钟。
3. DNS / IPv6 黑洞 —— 只解析出 IPv6（或解析为空）而后端没有 IPv6 出口，
   表现就是「解析成功但连接超时」，和当初 dockerpull.org 那个坑同源。

结论只能由实测得出，所以本模块**不猜**：每一条都写明测了什么、拿到什么。
"""
import email.utils
import http.client
import json
import socket
import ssl
import time
from datetime import datetime, timezone

# 行情源（业务相关）+ 公网 registry（用来区分「没出口」和「只是墙了行情源」）。
MARKET_HOSTS = ("qt.gtimg.cn", "web.ifzq.gtimg.cn", "push2.eastmoney.com")
EGRESS_HOSTS = ("registry-1.docker.io", "www.baidu.com")
ALL_HOSTS = MARKET_HOSTS + EGRESS_HOSTS

# 超过这个偏差就一定会影响 TLS 证书校验与行情时间戳。
CLOCK_SKEW_LIMIT_SECONDS = 300


def _resolve(host):
    infos = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
    v4 = sorted({item[4][0] for item in infos if item[0] == socket.AF_INET})
    v6 = sorted({item[4][0] for item in infos if item[0] == socket.AF_INET6})
    return {"ipv4": v4[:4], "ipv6": v6[:4]}


def _probe(host, timeout=6):
    """DNS → TCP:443 → TLS 证书校验，每步失败都记成可读原因。"""
    result = {"host": host}
    try:
        result["dns"] = _resolve(host)
    except OSError as error:
        result["dnsError"] = f"{type(error).__name__}: {error}"[:200]
        return result
    started = time.monotonic()
    try:
        with socket.create_connection((host, 443), timeout=timeout):
            result["tcp"] = True
    except OSError as error:
        result["tcp"] = False
        result["tcpError"] = f"{type(error).__name__}: {error}"[:200]
        return result
    try:
        with socket.create_connection((host, 443), timeout=timeout) as raw:
            with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as tls:
                result["tls"] = True
                result["latencyMs"] = int((time.monotonic() - started) * 1000)
                cert = tls.getpeercert() or {}
                result["certNotAfter"] = cert.get("notAfter")
    except ssl.SSLCertVerificationError as error:
        # 时钟错到证书有效期外时，最先炸的就是这里，而不是 TCP。
        result["tls"] = False
        result["tlsError"] = "certificate_verify_failed"
        result["tlsDetail"] = str(error)[:200]
    except OSError as error:
        result["tls"] = False
        result["tlsError"] = f"{type(error).__name__}: {error}"[:200]
    return result


def _clock_skew(hosts=MARKET_HOSTS, timeout=6):
    """用上游 HTTPS 响应头 `Date` 反推本地时钟偏差。

    不能拿本机时钟跟自己比——RTC 复位时本机认为的「现在」本来就不准。
    """
    failure = None
    for host in hosts:
        try:
            conn = http.client.HTTPSConnection(host, timeout=timeout, context=ssl.create_default_context())
            conn.request("HEAD", "/")
            response = conn.getresponse()
            header = response.getheader("Date")
            conn.close()
            if not header:
                failure = "上游没有返回 Date 头"
                continue
            remote = email.utils.parsedate_to_datetime(header)
            if remote.tzinfo is None:
                remote = remote.replace(tzinfo=timezone.utc)
            local = datetime.now(timezone.utc)
            return {"host": host, "localUtc": local.isoformat(timespec="seconds"),
                    "remoteUtc": remote.isoformat(timespec="seconds"),
                    "skewSeconds": round((local - remote).total_seconds())}
        except Exception as error:  # noqa: BLE001 - 自检要把任何异常都变成结论
            failure = f"{type(error).__name__}: {error}"[:200]
    return {"error": failure or "未取得 Date 头"}


def _verdict(probes, clock):
    """把探测结果收敛成一句人话 + 建议动作。判定顺序＝用户提出的三种原因。"""
    market = [p for p in probes if p["host"] in MARKET_HOSTS]
    egress = [p for p in probes if p["host"] in EGRESS_HOSTS]
    market_ok = [p for p in market if p.get("tls")]
    egress_ok = [p for p in egress if p.get("tls")]

    # 时钟错要先判：证书校验失败会伪装成「全线连不通」，如果按「没外网」收尾就彻底跑偏了。
    cert_failed = any(p.get("tlsError") == "certificate_verify_failed" for p in probes)
    skew = clock.get("skewSeconds")
    if cert_failed or (skew is not None and abs(skew) > CLOCK_SKEW_LIMIT_SECONDS):
        detail = f"与上游相差 {skew} 秒" if skew is not None else "已出现证书验证失败"
        return {"cause": "clock_skew",
                "summary": f"系统时钟不准（{detail}）：HTTPS 在握手阶段就失败，所有源会同时挂。",
                "action": "校准 NAS 时间（NTP 同步）后重启容器；这是 Z4Pro 断电后 RTC 复位的典型症状。"}

    if not market_ok and not egress_ok:
        ipv6_only = [p["host"] for p in probes
                     if p.get("dns") and p["dns"].get("ipv6") and not p["dns"].get("ipv4")]
        if ipv6_only:
            return {"cause": "dns_ipv6_blackhole",
                    "summary": "只解析到 IPv6 且连不通：容器没有 IPv6 出口，DNS 却优先给了 IPv6 地址。",
                    "action": "在容器/路由层关闭 IPv6（或让 DNS 只返回 A 记录）后重试。"}
        return {"cause": "no_egress",
                "summary": "连公网 registry 也连不通：容器整体没有外网出口，不是行情源的问题。",
                "action": "检查 NAS 的默认网关与容器网络（bridge 是否走宿主机出网），修好后 /v1/market/quotes 才会恢复。"}
    if not market_ok and egress_ok:
        return {"cause": "market_source_blocked",
                "summary": "公网能出去，但行情源三个域名全部失败：被 DNS 污染 / 拦截，或源站域名变更。",
                "action": "在容器内 curl 一次行情源确认；必要时把行情源改成可达的备用域名。"}
    return {"cause": "ok",
            "summary": "外网、DNS、TLS 与时钟均正常；若行情仍 502/503，问题在源站或解析结果漂移。",
            "action": "稍后重试，并对比 /health 的 workers 状态。"}


def collect():
    probes = [_probe(host) for host in ALL_HOSTS]
    clock = _clock_skew()
    return {"checkedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "clock": clock,
            "probes": probes,
            "verdict": _verdict(probes, clock)}


def main():
    report = collect()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("\n结论：" + report["verdict"]["summary"])
    print("建议：" + report["verdict"]["action"])


if __name__ == "__main__":
    main()
