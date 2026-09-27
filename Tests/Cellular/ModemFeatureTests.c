#include <stdio.h>
#include <string.h>
static int fake_query(const char *, char *, char *);
#define FEATURE_QUERY(m,c,r,e,t) fake_query(c,r,e)
#define main helper_main_unused
#include "../../Native/modem-helper.c"
#undef main

static int current_mode, expected_calls, calls, fail_step;
static const char *commands[20], *responses[20];
static int fake_query(const char *command, char *response, char *error) {
    if (calls >= expected_calls || strcmp(command,commands[calls])) {
        fprintf(stderr,"Unexpected command: %s at %d\n",command,calls); exit(1);
    }
    strcpy(response,responses[calls]); error[0]=0;
    int result = calls == fail_step ? 0 : 1; calls++; return result;
}
static void setup(void) { calls=0; expected_calls=0; fail_step=-1; current_mode=1; }
static void add(const char *c, const char *r) { commands[expected_calls]=c; responses[expected_calls++]=r; }
static void mode_reads(void) {
    add("AT+QCFG=\"usbnet\"","+QCFG: \"usbnet\",1\r\nOK\r\n");
    add("AT+QCFG=?","+QCFG: \"usbnet\",<0-3>\r\nOK\r\n");
}
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"Failed line %d\n",__LINE__); exit(1); } } while(0)
int main(void) {
    Modem m={0}; Snapshot s;
    setup(); mode_reads(); s=snapshot_empty(); switch_mode(&m,&s,2,0);
    CHECK(!s.success && !s.modeWritten && calls==2);
    setup(); mode_reads(); s=snapshot_empty(); switch_mode(&m,&s,1,1);
    CHECK(s.success && !s.modeWritten && calls==2);
    setup(); mode_reads(); add("AT+QCFG=\"usbnet\",2","ERROR\r\n"); fail_step=2;
    s=snapshot_empty(); switch_mode(&m,&s,2,1); CHECK(!s.success && !s.modeWritten && calls==3);
    setup(); mode_reads(); add("AT+QCFG=\"usbnet\",2","OK\r\n");
    add("AT+QCFG=\"usbnet\"","+QCFG: \"usbnet\",1\r\nOK\r\n");
    s=snapshot_empty(); switch_mode(&m,&s,2,1); CHECK(!s.success && s.modeWritten && !s.restartAccepted && calls==4);
    setup(); mode_reads(); add("AT+QCFG=\"usbnet\",2","OK\r\n");
    add("AT+QCFG=\"usbnet\"","+QCFG: \"usbnet\",2\r\nOK\r\n"); add("AT+CFUN=1,1","OK\r\n");
    s=snapshot_empty(); switch_mode(&m,&s,2,1); CHECK(s.success && s.modeWritten && s.restartAccepted && calls==5);
    const char *store = "+CPMS: \"ME\",2,23,\"ME\",2,23,\"ME\",2,23\r\nOK\r\n";
    setup(); add("AT+CMGF?","+CMGF: 0\r\nOK\r\n"); add("AT+CPMS?",store); add("AT+CPMS?",store);
    add("AT+CMGL=4,1","ERROR\r\n"); fail_step=3;
    s=snapshot_empty(); read_sms(&m,&s,"ME",false);
    CHECK(!s.success && !strcmp(s.error,"read_requires_marking") && calls==4);
    setup(); add("AT+CMGF?","+CMGF: 1\r\nOK\r\n"); add("AT+CPMS?",store); add("AT+CPMS?",store);
    add("AT+CMGF=0","OK\r\n"); add("AT+CMGL=4,1","ERROR\r\n"); fail_step=4;
    add("AT+CMGL=4","OK\r\n"); add("AT+CMGF=1","OK\r\n");
    s=snapshot_empty(); read_sms(&m,&s,"ME",true);
    CHECK(s.success && !s.smsPreservesUnread && calls==7);
    setup(); add("AT+CMGF?","+CMGF: 0\r\nOK\r\n"); add("AT+CPMS?",store); add("AT+CPMS=\"SM\"","OK\r\n");
    add("AT+CPMS?","+CPMS: \"SM\",0,50,\"ME\",2,23,\"ME\",2,23\r\nOK\r\n");
    add("AT+CMGL=4,1","OK\r\n"); add("AT+CPMS=\"ME\"","OK\r\n");
    s=snapshot_empty(); read_sms(&m,&s,"SM",false); CHECK(s.success && s.smsPreservesUnread && s.smsUsed==0 && calls==6);
    alarm(0);
    puts("PASS: 8 mocked AT transactions: stale/same-mode guard, rejected write, readback failure, confirmed reboot, unread permission gate, format/storage restoration. No USB access.");
    return 0;
}
