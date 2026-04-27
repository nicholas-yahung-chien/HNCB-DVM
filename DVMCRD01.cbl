      *    ***************************************
      *    PROGRAM-ID: DVMCRD01
      *    FUNCTION  : 金融卡戶各類事故紀錄統計掃檔作業
      *                輸入日期區間搜尋
      *    JCL       : TPSCRD01
      *    AUTHOR    : HC2077
      *    REF DB'S  : CHDB
      *    ***************************************
      *    20070302-HC2077 新增
      *    修改目的：
      *    20070326-HC2077 增加自選輸入報表日期
      *    20090318-1.HC2077 調整事故條件
      *            2.SM2091 配合民國百年修改 CHEDXD
      *    ***************************************
           IDENTIFICATION DIVISION.
           PROGRAM-ID. DVMCRD01.
           ENVIRONMENT DIVISION.
           CONFIGURATION SECTION.
           SOURCE-COMPUTER. IBM-370 WITH DEBUGGING MODE.
           OBJECT-COMPUTER. IBM-370.
           INPUT-OUTPUT SECTION.
           FILE-CONTROL.
               SELECT DATEFL   ASSIGN TO S-DATEFL.
               SELECT ATMSTCP  ASSIGN TO S-ATMSTCP.
DVM            SELECT CHRFILE  ASSIGN TO S-CHRFILE.
DVM            SELECT CEDFILE  ASSIGN TO S-CEDFILE.
           DATA DIVISION.
           FILE SECTION.
           FD  DATEFL
               LABEL  RECORDS  ARE STANDARD
               RECORD CONTAINS  80 CHARACTERS
               BLOCK  CONTAINS   0 RECORDS.
           01  DATERCD.
               05  TYPE-RPT       PIC X.
960326         05  BEGINDATE      PIC 9(08).
960326         05  ENDDATE        PIC 9(08).
               05  FILLER         PIC X(63).
           FD  ATMSTCP
               LABEL RECORD ARE OMITTED
               BLOCK  CONTAINS    0 RECORDS.
           01  W-REC              PIC X(80).
DVM        FD  CHRFILE
DVM            LABEL RECORDS ARE STANDARD
DVM            RECORD CONTAINS 475 CHARACTERS
DVM            BLOCK CONTAINS 0 RECORDS.
DVM        01  CHRREC.
DVM            05  CHR-REC        PIC X(439).
DVM            05  CHR-KEY        PIC X(12).
DVM            05  CHR-KEYH       PIC X(24).
DVM        FD  CEDFILE
DVM            LABEL RECORDS ARE STANDARD
               RECORD CONTAINS 94 CHARACTERS
               BLOCK CONTAINS 0 RECORDS.
           01  CEDREC.
               05  CED-REC        PIC X(52).
               05  CED-KEY        PIC X(18).
               05  CED-KEYH       PIC X(24).
      *    ******************************************************
           WORKING-STORAGE SECTION.
      *    ******************************************************
      *    COPY TRACEWK SUPPRESS.
           77  SYNX               PIC X(4)  VALUE 'SYNC'.
           01  ERR-SW             PIC X(1)  VALUE SPACES.
           01  CHR-EOF            PIC X(1)  VALUE SPACES.
           01  CHCED-EOF          PIC X(1)  VALUE SPACES.
           01  DATE-SW            PIC X(01) VALUE 'N'.
               88 DATE-OK                  VALUE 'Y'.
           01  WK-CH-KEY          PIC X(12) VALUE SPACES.
           01  WK-CHCED-KEY       PIC X(06) VALUE SPACES.
           01  WK-DATE            PIC 9(8)  VALUE 0.
           01  WK-DATE8.
               05 WK-YY           PIC 9(4)  VALUE 0.
               05 WK-MM           PIC 9(2)  VALUE 0.
               05 WK-DD           PIC 9(2)  VALUE 0.
090318     01  WK-CHEDXD8         PIC X(11) VALUE SPACES.
           01  BEGINTIME.
               05 BEGIN-YY        PIC 9(4)  VALUE 0.
               05 BEGIN-MM        PIC 9(2)  VALUE 0.
               05 BEGIN-DD        PIC 9(2)  VALUE 01.
           01  ENDTIME.
               05 END-YY          PIC 9(4)  VALUE 0.
               05 END-MM          PIC 9(2)  VALUE 0.
               05 END-DD          PIC 9(2)  VALUE 31.
           01  ROOT-CNT           PIC 9(8)  VALUE ZEROS.
           01  CHIL-CNT           PIC 9(8)  VALUE ZEROS.
           01  ATM-REC.
               05 OUT-FROMDATE    PIC 9(08).
               05 OUT-TODATE      PIC 9(08).
               05 OUT-CHRAC       PIC X(12).
               05 OUT-CHRNPD      PIC X(10).
               05 OUT-CHRCCC      PIC X(02).
               05 OUT-CHRSTC      PIC X(01).
               05 FILLER          PIC X(39).
      *    -------
           COPY FUNCCODE SUPPRESS.
           COPY CHSSA   SUPPRESS.
           COPY CHRSEG  SUPPRESS.
           COPY CHCEDSEG SUPPRESS.
           COPY CMDWCVDT SUPPRESS.
      *    PSB=ATM030
DVM        01 DVM-WORK.
DVM           05 W1-CHR-ID        PIC X(24) VALUE LOW-VALUE.
DVM           05 W1-CED-ID        PIC X(24) VALUE LOW-VALUE.
DVM   *    LINKAGE SECTION.
           01  IOPCB.  COPY DBPCB  SUPPRESS.
           01  ACPCB.  COPY DBPCB  SUPPRESS.
           01  CHPCB.  COPY DBPCB  SUPPRESS.
DVM        LINKAGE SECTION.
      *    ******************************************************
DVM        PROCEDURE DIVISION.
DVM   *    PROCEDURE DIVISION USING IOPCB ACPCB CHPCB.
      *    ******************************************************
               MOVE '3'                    TO CMITYP.
               CALL 'CMDWCVDT' USING CMDWCVDT.
               IF CMOEMG = SPACES
                   MOVE CMODATE            TO WK-DATE8
               ELSE
                   MOVE FUNCTION CURRENT-DATE(1:8) TO WK-DATE8
                   COMPUTE WK-YY = WK-YY - 1911
               END-IF.
               MOVE SPACES                 TO CHR-EOF CHCED-EOF.
               OPEN INPUT DATEFL OUTPUT ATMSTCP.
DVM            OPEN INPUT CHRFILE CEDFILE.
      *    檢驗執行週 (W) 報表或月 (M) 報表
               READ DATEFL.
               IF BEGINDATE = SPACES AND ENDDATE = SPACES
                   IF TYPE-RPT = 'W' AND WK-DD NOT = 01
                       COMPUTE WK-DD = WK-DD - 1
                       MOVE WK-YY TO BEGIN-YY END-YY
                       MOVE WK-MM TO BEGIN-MM END-MM
                       MOVE WK-DD TO END-DD
TEST                   MOVE '00960209' TO BEGINTIME ENDTIME
                       MOVE 'Y'        TO DATE-SW
                   ELSE
                       IF TYPE-RPT = 'M'
                           IF WK-DD < 20
                               IF WK-MM = 01
                                   COMPUTE WK-YY = WK-YY - 1
                                   MOVE 12 TO WK-MM
                               ELSE
                                   COMPUTE WK-MM = WK-MM - 1
                               END-IF
                           END-IF
                           MOVE WK-YY TO BEGIN-YY END-YY
                           MOVE WK-MM TO BEGIN-MM END-MM
                           MOVE 'Y'   TO DATE-SW
                       END-IF
                   END-IF
               ELSE
960326             COMPUTE BEGINDATE = BEGINDATE - 19110000
960326             COMPUTE ENDDATE   = ENDDATE   - 19110000
960326             MOVE BEGINDATE    TO BEGINTIME
960326             MOVE ENDDATE      TO ENDTIME
960326             MOVE 'Y'          TO DATE-SW
               END-IF.
               DISPLAY ' BEGINTIME : ' BEGINTIME.
               DISPLAY ' ENDTIME : '   ENDTIME.
               IF DATE-OK
DVM                READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
DVM                    NOT AT END MOVE CED-KEYH TO W1-CED-ID
DVM                END-READ
                   PERFORM 100-MAIN-RTN UNTIL CHR-EOF = 'Y' OR ERR-SW = 'Y'
               END-IF.
               DISPLAY 'CHR   COUNT =' ROOT-CNT.
               DISPLAY 'CHCED COUNT =' CHIL-CNT.
DVM            CALL 'CBLTDLI' USING SYNX IOPCB.
               CLOSE DATEFL ATMSTCP.
DVM            CLOSE CHRFILE CEDFILE.
               IF ERR-SW NOT = SPACES
                   MOVE 1044 TO RETURN-CODE
                   DISPLAY ' 殘念!! '
               ELSE
                   DISPLAY ' 成功!! '
               END-IF.
               GOBACK.
      *    ******************************************************
           100-MAIN-RTN.
      *    ******************************************************
DVM            CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.
DVM            MOVE SPACES TO PSTATUS OF CHPCB.
DVM            PERFORM 1000-GN-CHR.
               IF PSTATUS OF CHPCB = SPACES OR 'FW'
                   ADD 1              TO ROOT-CNT
                   MOVE CHRCAC        TO WK-CH-KEY
                   IF ERR-SW = SPACES
                       MOVE SPACES    TO CHCED-EOF
                       MOVE 0         TO WK-DATE
                       PERFORM 110-GNP-CHCEDSEG-RTN
                           UNTIL CHCED-EOF = 'Y' OR ERR-SW NOT = SPACES
                   END-IF
               ELSE
                   IF PSTATUS OF CHPCB = 'GE' OR 'GB'
                       MOVE 'Y'       TO CHR-EOF
                   ELSE
                       MOVE 'Y'       TO ERR-SW
                       DISPLAY 'GN CHR ERROR !!' PSTATUS OF CHPCB
                               '(KEY)= ' WK-CH-KEY
                   END-IF
               END-IF.
      *    ******************************************************
           110-GNP-CHCEDSEG-RTN.
      *    ******************************************************
DVM            CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.
DVM            PERFORM 1010-GNP-CED.
               IF PSTATUS OF CHPCB = SPACES OR 'FW'
                   ADD 1               TO CHIL-CNT
                   MOVE 0              TO WK-DATE
090318*            MOVE CHEDXD         TO WK-DATE(3:6)
090318             IF CHEDXD IS NUMERIC
090318                 MOVE CHEDXD     TO WK-DATE(3:6)
090318             ELSE
090318                 MOVE SPACES     TO WK-CHEDXD8
090318                 MOVE CHEDXD8    TO WK-CHEDXD8
090318                 MOVE WK-CHEDXD8(4:8) TO WK-DATE
090318             END-IF
960326             IF WK-DATE NOT < BEGINTIME AND WK-DATE NOT > ENDTIME
TEST  *                DISPLAY '#' ROOT-CNT '#' WK-CH-KEY '/' CHEDSQ
TEST  *                        '/' CHESTC '/' CHECRT
090318                 IF CHESTC = '6' OR '2' OR '3'
                           MOVE CHESTC TO OUT-CHRSTC
                           PERFORM 111-WRITE-DATA
                       ELSE
                           IF CHECRT = 'H'
                               MOVE CHECRT TO OUT-CHRSTC
                               PERFORM 111-WRITE-DATA
                           END-IF
                       END-IF
                   END-IF
               ELSE
                   IF PSTATUS OF CHPCB = 'GB' OR 'GE'
                       MOVE 'Y'        TO CHCED-EOF
                   ELSE
                       MOVE 'Y'        TO ERR-SW
                       DISPLAY 'GNP CHCED ERROR!! ' PSTATUS OF CHPCB
                               '(KEY)= ' WK-CH-KEY ': ' CHCEDSEG
                   END-IF
               END-IF.
      *    ******************************************************
           111-WRITE-DATA.
      *    ******************************************************
               MOVE CHRCAC             TO OUT-CHRAC.
               MOVE CHRCID             TO OUT-CHRNPD.
090318         IF CHECSN = CHRCSN
090318             MOVE CHRCCC         TO OUT-CHRCCC
090318         ELSE
090318             IF CHECSN = CHRCSN1
090318                 MOVE CHRCCC1    TO OUT-CHRCCC
090318             END-IF
090318         END-IF.
               MOVE BEGINTIME          TO OUT-FROMDATE.
               MOVE ENDTIME            TO OUT-TODATE.
               WRITE W-REC  FROM ATM-REC.
      *    ******************************************************
DVM        1000-GN-CHR.
DVM   *    ******************************************************
DVM            READ CHRFILE AT END MOVE 'GB' TO PSTATUS OF CHPCB
DVM                NOT AT END
DVM                    MOVE CHR-REC TO CHRSEG
DVM                    MOVE CHR-KEYH TO W1-CHR-ID
DVM                    DISPLAY ' CHR KEY : ' CHR-KEY
DVM            END-READ.
DVM   *    ******************************************************
DVM        1010-GNP-CED.
DVM   *    ******************************************************
DVM            IF W1-CED-ID = W1-CHR-ID
DVM                MOVE CED-REC TO CHCEDSEG
DVM                MOVE SPACES TO PSTATUS OF CHPCB
DVM                DISPLAY ' CED KEY : ' CED-KEY
DVM                READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
DVM                    NOT AT END MOVE CED-KEYH TO W1-CED-ID
DVM                END-READ
DVM            ELSE
DVM                MOVE 'GE'    TO PSTATUS OF CHPCB
DVM            END-IF.
