import socket, time, sys
iface="169.254.181.135"; seconds=float(sys.argv[1])
socks={}
for g in ("239.69.16.1","239.69.121.9"):
    s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT,1)
    s.bind((g,5004)); s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton(g)+socket.inet_aton(iface))
    s.setblocking(False); socks[g]=s
stats={g:{"pkts":0,"peak":[0]*8,"hits":0,"first_hit":None} for g in socks}
end=time.time()+seconds; t0=time.time()
import select
while time.time()<end:
    r,_,_=select.select(list(socks.values()),[],[],0.2)
    for s in r:
        g=[k for k,v in socks.items() if v is s][0]
        try:
            while True:
                d=s.recv(2000); st=stats[g]; st["pkts"]+=1; body=d[12:]
                for f in range(len(body)//24):
                    for ch in range(8):
                        v=abs(int.from_bytes(body[f*24+ch*3:f*24+ch*3+3],'big',signed=True))
                        if v>st["peak"][ch]: st["peak"][ch]=v
                        if ch==0 and v>=0x100000:
                            st["hits"]+=1
                            if st["first_hit"] is None: st["first_hit"]=round(time.time()-t0,1)
        except BlockingIOError: pass
for g,st in stats.items():
    print(f"{g}: {st['pkts']} packets, ch1 impulse hits (>=0.125 FS) {st['hits']} first at {st['first_hit']} s, per-channel peak {[hex(p) for p in st['peak']]}")
