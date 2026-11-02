"""Check both lifetime boundaries in real kernel sources, before and after patching."""
import pathlib
import re
import sys

mode, root = sys.argv[1:]
assert mode in ("vulnerable", "fixed")
for name, function, pointer in (
    ("af_inet.c", "inet_sock_destruct", "inet->inet_opt"),
    ("tcp_ipv4.c", "tcp_v4_reqsk_destructor", "inet_rsk(req)->ireq_opt"),
):
    text = (pathlib.Path(root) / "net/ipv4" / name).read_text()
    body = re.search(r"(?:static )?void " + function + r"\([^\n]+\)\n\{(.*?)\n\}", text, re.S).group(1)
    old = "kfree(rcu_dereference_protected(" + pointer + ", 1));"
    new = "kfree_rcu(rcu_dereference_protected(" + pointer + ", 1), rcu);"
    assert body.count(old) == (mode == "vulnerable"), (name, mode, "immediate free")
    assert body.count(new) == (mode == "fixed"), (name, mode, "deferred free")
