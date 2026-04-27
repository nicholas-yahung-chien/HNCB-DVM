# IBM DVM COBOL 程式優化改寫指引

## 目錄

- [簡介](#簡介)
- [優化原理](#優化原理)
- [改寫步驟指引](#改寫步驟指引)
- [程式碼轉換模式](#程式碼轉換模式)
- [注意事項與最佳實踐](#注意事項與最佳實踐)
- [範例對照](#範例對照)
- [附錄](#附錄)

---

## 簡介

### 什麼是 IBM DVM？

IBM DVM (Data Virtualization Manager) 是一套資料虛擬化解決方案，可以將 IMS 階層式資料庫的 segment 資料預先掃檔寫入 sequential files，讓 COBOL 程式改為讀取這些平面檔案，而非直接存取 IMS 資料庫。

### 優化目的與效益

**效能提升**
- 減少對 IMS 子系統的即時存取需求
- Sequential file 讀取速度通常優於階層式資料庫查詢
- 可預先排序檔案以優化讀取順序

**系統穩定性**
- 降低對 IMS 子系統的依賴
- 批次作業不受 IMS 可用性影響
- 減少資料庫鎖定競爭

**維護便利性**
- 標準 COBOL I/O 操作更易於理解和維護
- 測試環境可使用檔案而非完整 IMS 環境
- 除錯更加直觀

**成本效益**
- 減少 IMS 授權和運行成本
- 降低系統資源消耗
- 簡化災難復原流程

---

## 優化原理

### IMS 階層式資料庫結構

IMS 使用階層式資料模型，資料以 Parent-Child 關係組織：

```
CHR (Root Segment - 金融卡戶主檔)
 └── CHCED (Child Segment - 事故紀錄明細檔)
```

**存取方式**：
- 使用 `CBLTDLI` 呼叫 DL/I 介面
- 透過 PCB (Program Communication Block) 控制
- 使用 SSA (Segment Search Arguments) 定位資料

### Sequential Files 平面檔案結構

DVM 將階層式資料轉換為平面檔案：

| IMS Segment | Sequential File | 記錄長度 | 關鍵欄位 |
|-------------|----------------|---------|---------|
| CHR (CHRSEG) | CHRFILE | 475 bytes | CHR-KEY (12), CHR-KEYH (24) |
| CHCED (CHCEDSEG) | CEDFILE | 94 bytes | CED-KEY (18), CED-KEYH (24) |

**記錄結構**：
```
CHRFILE: [資料區 439 bytes] + [主鍵 12 bytes] + [階層鍵 24 bytes]
CEDFILE: [資料區 52 bytes] + [主鍵 18 bytes] + [階層鍵 24 bytes]
```

### 階層關係模擬機制

**關鍵概念：階層鍵 (Hierarchical Key)**

階層鍵是一個 24-byte 的欄位，用於模擬 IMS 的 Parent-Child 關係：

- **CHR-KEYH**：CHR 記錄的階層鍵
- **CED-KEYH**：CHCED 記錄的階層鍵
- **關聯規則**：當 `CHR-KEYH = CED-KEYH` 時，表示該 CHCED 屬於該 CHR

**運作原理**：

```
1. 讀取 CHR 記錄 → 保存 CHR-KEYH 到工作區 (W1-CHR-ID)
2. 讀取 CED 記錄 → 比對 CED-KEYH 與 W1-CHR-ID
3. 若相等 → 該 CED 屬於當前 CHR
4. 若不等 → 當前 CHR 已無更多 Child，進入下一個 CHR
```

### 核心轉換公式

```
IMS 階層式存取 → Sequential File 平面存取 + 階層鍵比對

GN (Get Next Root)     → READ CHRFILE + 保存階層鍵
GNP (Get Next Child)   → 比對階層鍵 + READ CEDFILE
PSTATUS 判斷           → AT END 判斷 + 階層鍵比對結果
CBLTDLI SYNX          → (移除，不需要)
```

---

## 改寫步驟指引

### 步驟 1：新增 Sequential File 定義

在 `ENVIRONMENT DIVISION` 的 `FILE-CONTROL` 段落新增檔案定義：

```cobol
SELECT CHRFILE  ASSIGN TO S-CHRFILE.
SELECT CEDFILE  ASSIGN TO S-CEDFILE.
```

在 `DATA DIVISION` 的 `FILE SECTION` 新增檔案描述：

```cobol
FD  CHRFILE
    RECORD CONTAINS 475 CHARACTERS.
    01  CHRREC.
        05  CHR-REC        PIC X(439).
        05  CHR-KEY        PIC X(12).
        05  CHR-KEYH       PIC X(24).

FD  CEDFILE
    RECORD CONTAINS 94 CHARACTERS.
    01  CEDREC.
        05  CED-REC        PIC X(52).
        05  CED-KEY        PIC X(18).
        05  CED-KEYH       PIC X(24).
```

### 步驟 2：新增工作區欄位

在 `WORKING-STORAGE SECTION` 新增階層鍵暫存區：

```cobol
01 DVM-WORK.
   05 W1-CHR-ID        PIC X(24) VALUE LOW-VALUE.
   05 W1-CED-ID        PIC X(24) VALUE LOW-VALUE.
```

### 步驟 3：修改 LINKAGE SECTION

註解掉原有的 `PROCEDURE DIVISION USING` 語句：

```cobol
*LINKAGE SECTION.
01  IOPCB.  COPY DBPCB  SUPPRESS.
01  ACPCB.  COPY DBPCB  SUPPRESS.
01  CHPCB.  COPY DBPCB  SUPPRESS.
LINKAGE SECTION.

PROCEDURE DIVISION.
*PROCEDURE DIVISION USING IOPCB ACPCB CHPCB.
```

**注意**：保留 PCB 定義但不使用，以維持 `PSTATUS OF CHPCB` 欄位的相容性。

### 步驟 4：修改檔案開啟邏輯

**原始程式**：
```cobol
OPEN INPUT DATEFL OUTPUT ATMSTCP.
```

**改寫後**：
```cobol
OPEN INPUT DATEFL OUTPUT ATMSTCP.
OPEN INPUT CHRFILE CEDFILE.

*初始化：預讀第一筆 CEDFILE
READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
    NOT AT END MOVE CED-KEYH TO W1-CED-ID
END-READ.
```

### 步驟 5：轉換 CBLTDLI 呼叫

#### 5.1 轉換 GN (Get Next Root)

**原始程式**：
```cobol
CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.
```

**改寫後**：
```cobol
*CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.
MOVE SPACES TO PSTATUS OF CHPCB.
PERFORM 1000-GN-CHR.
```

新增 Paragraph：
```cobol
1000-GN-CHR.
    READ CHRFILE AT END MOVE 'GB' TO PSTATUS OF CHPCB
        NOT AT END
            MOVE CHR-REC TO CHRSEG
            MOVE CHR-KEYH TO W1-CHR-ID
            DISPLAY ' CHR KEY : ' CHR-KEY
    END-READ.
```

#### 5.2 轉換 GNP (Get Next within Parent)

**原始程式**：
```cobol
CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.
```

**改寫後**：
```cobol
*CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.
PERFORM 1010-GNP-CED.
```

新增 Paragraph：
```cobol
1010-GNP-CED.
    IF W1-CED-ID = W1-CHR-ID
        MOVE CED-REC TO CHCEDSEG
        MOVE SPACES TO PSTATUS OF CHPCB
        DISPLAY ' CED KEY : ' CED-KEY
        READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
            NOT AT END MOVE CED-KEYH TO W1-CED-ID
        END-READ
    ELSE
        MOVE 'GE' TO PSTATUS OF CHPCB
    END-IF.
```

### 步驟 6：修改檔案關閉邏輯

**原始程式**：
```cobol
CALL 'CBLTDLI' USING SYNX IOPCB.
CLOSE DATEFL ATMSTCP.
```

**改寫後**：
```cobol
*CALL 'CBLTDLI' USING SYNX IOPCB.
CLOSE DATEFL ATMSTCP.
CLOSE CHRFILE CEDFILE.
```

### 步驟 7：驗證狀態碼處理邏輯

確認原程式的狀態碼判斷邏輯不需修改，因為我們已經模擬了相同的狀態碼：

| IMS Status | 意義 | Sequential File 對應 |
|-----------|------|---------------------|
| SPACES | 成功 | `NOT AT END` + 階層鍵匹配 |
| 'FW' | 成功 (Forward) | 同 SPACES |
| 'GB' | End of Database | `AT END` (CHR) |
| 'GE' | End of Children | 階層鍵不匹配 (CED) |

---

## 程式碼轉換模式

### 模式 1：Root Segment 讀取 (GN)

**用途**：讀取下一筆 Root Segment (CHR)

**轉換前**：
```cobol
CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.
IF PSTATUS OF CHPCB = SPACES OR 'FW'
    *處理 CHR 資料
ELSE
    IF PSTATUS OF CHPCB = 'GB'
        *資料庫結束
    END-IF
END-IF.
```

**轉換後**：
```cobol
*CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.
MOVE SPACES TO PSTATUS OF CHPCB.
PERFORM 1000-GN-CHR.
IF PSTATUS OF CHPCB = SPACES OR 'FW'
    *處理 CHR 資料 (邏輯不變)
ELSE
    IF PSTATUS OF CHPCB = 'GB'
        *資料庫結束 (邏輯不變)
    END-IF
END-IF.

*新增 Paragraph
1000-GN-CHR.
    READ CHRFILE AT END MOVE 'GB' TO PSTATUS OF CHPCB
        NOT AT END
            MOVE CHR-REC TO CHRSEG
            MOVE CHR-KEYH TO W1-CHR-ID
    END-READ.
```

**關鍵點**：
- 使用 `READ CHRFILE` 取代 `CBLTDLI GN`
- `AT END` 對應 IMS 的 'GB' 狀態
- 保存 `CHR-KEYH` 到 `W1-CHR-ID` 供後續比對
- 原有的狀態判斷邏輯完全不變

### 模式 2：Child Segment 讀取 (GNP)

**用途**：讀取當前 Parent 下的下一筆 Child Segment (CHCED)

**轉換前**：
```cobol
CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.
IF PSTATUS OF CHPCB = SPACES OR 'FW'
    *處理 CHCED 資料
ELSE
    IF PSTATUS OF CHPCB = 'GE'
        *該 Parent 下無更多 Child
    END-IF
END-IF.
```

**轉換後**：
```cobol
*CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.
PERFORM 1010-GNP-CED.
IF PSTATUS OF CHPCB = SPACES OR 'FW'
    *處理 CHCED 資料 (邏輯不變)
ELSE
    IF PSTATUS OF CHPCB = 'GE'
        *該 Parent 下無更多 Child (邏輯不變)
    END-IF
END-IF.

*新增 Paragraph
1010-GNP-CED.
    IF W1-CED-ID = W1-CHR-ID
        MOVE CED-REC TO CHCEDSEG
        MOVE SPACES TO PSTATUS OF CHPCB
        READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
            NOT AT END MOVE CED-KEYH TO W1-CED-ID
        END-READ
    ELSE
        MOVE 'GE' TO PSTATUS OF CHPCB
    END-IF.
```

**關鍵點**：
- 使用階層鍵比對 (`W1-CED-ID = W1-CHR-ID`) 模擬 Parent-Child 關係
- 階層鍵相等時，表示該 CED 屬於當前 CHR
- 階層鍵不等時，設定 'GE' 狀態，表示無更多 Child
- 採用「預讀」策略：讀取下一筆並保存其階層鍵
- 原有的狀態判斷邏輯完全不變

### 模式 3：IMS 同步點 (SYNX)

**用途**：IMS 交易同步點

**轉換前**：
```cobol
CALL 'CBLTDLI' USING SYNX IOPCB.
```

**轉換後**：
```cobol
*CALL 'CBLTDLI' USING SYNX IOPCB.
*Sequential File 不需要同步點，直接註解掉
```

**關鍵點**：
- Sequential File 不需要交易同步機制
- 直接註解掉即可，不需替代邏輯

### 模式 4：其他 DL/I 功能碼

如果程式使用其他 DL/I 功能碼，可參考以下對應：

| DL/I 功能碼 | 用途 | Sequential File 對應 |
|------------|------|---------------------|
| **GU** | Get Unique | 需要在檔案中搜尋特定鍵值 |
| **GHU** | Get Hold Unique | 同 GU (Sequential File 無鎖定機制) |
| **GHN** | Get Hold Next | 同 GN |
| **GHNP** | Get Hold Next in Parent | 同 GNP |
| **ISRT** | Insert | 不適用 (Sequential File 為唯讀) |
| **REPL** | Replace | 不適用 (Sequential File 為唯讀) |
| **DLET** | Delete | 不適用 (Sequential File 為唯讀) |

**注意**：DVM 優化主要適用於唯讀查詢程式。如果程式需要更新資料庫，則不適合使用此方法。

---

## 注意事項與最佳實踐

### 1. 適用場景

**適合使用 DVM 優化的程式**：
- ✅ 批次查詢報表程式
- ✅ 資料擷取與轉換程式
- ✅ 唯讀分析程式
- ✅ 資料稽核程式

**不適合使用 DVM 優化的程式**：
- ❌ 線上交易程式 (需要即時資料)
- ❌ 需要更新資料庫的程式 (ISRT, REPL, DLET)
- ❌ 需要資料庫鎖定機制的程式
- ❌ 需要複雜 SSA 查詢的程式

### 2. 階層鍵設計原則

**長度選擇**：
- 階層鍵長度應足以唯一識別 Parent-Child 關係
- 範例使用 24 bytes，實際長度依資料特性調整
- 建議使用固定長度以簡化比對邏輯

**內容組成**：
- 通常包含 Parent 的主鍵
- 可能包含額外的排序鍵或時間戳記
- 確保 Child 的階層鍵與其 Parent 相同

**初始化**：
- 使用 `LOW-VALUE` 初始化工作區階層鍵
- 使用 `HIGH-VALUE` 表示檔案結束

### 3. 預讀策略

**為什麼需要預讀**：
- Sequential File 無法「偷看」下一筆記錄
- 需要提前知道下一筆的階層鍵以判斷是否屬於同一 Parent
- 預讀可以避免多餘的檔案操作

**實作要點**：
```cobol
*初始化時預讀第一筆
READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
    NOT AT END MOVE CED-KEYH TO W1-CED-ID
END-READ.

*處理完當前記錄後立即預讀下一筆
READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
    NOT AT END MOVE CED-KEYH TO W1-CED-ID
END-READ.
```

### 4. 狀態碼相容性

**保留 PCB 結構**：
- 即使不使用 IMS，仍保留 PCB 定義
- 使用 `PSTATUS OF CHPCB` 欄位模擬 IMS 狀態碼
- 原有的錯誤處理邏輯可以完全不變

**狀態碼對應表**：
```cobol
*成功
MOVE SPACES TO PSTATUS OF CHPCB.

*資料庫結束
MOVE 'GB' TO PSTATUS OF CHPCB.

*無更多 Child
MOVE 'GE' TO PSTATUS OF CHPCB.
```

### 5. 檔案排序要求

**CHRFILE 排序**：
- 必須按 CHR-KEYH 排序
- 確保相同 Parent 的記錄集中在一起

**CEDFILE 排序**：
- 必須按 CED-KEYH 排序
- 同一 Parent 的 Child 記錄必須連續
- 建議在 CED-KEYH 內再按業務邏輯排序 (如日期、序號)

**排序範例 (JCL)**：
```jcl
//SORT1   EXEC PGM=SORT
//SORTIN  DD DSN=原始.CHRFILE,DISP=SHR
//SORTOUT DD DSN=排序後.CHRFILE,DISP=(NEW,CATLG,DELETE)
//SYSIN   DD *
  SORT FIELDS=(452,24,CH,A)  ← 按 CHR-KEYH 排序
/*
```

### 6. 測試策略

**單元測試**：
1. 準備測試資料檔案
2. 驗證單一 Parent 無 Child 的情況
3. 驗證單一 Parent 有多筆 Child 的情況
4. 驗證多個 Parent 的情況
5. 驗證空檔案的情況

**比對測試**：
1. 使用相同輸入資料
2. 分別執行原始程式 (IMS) 和改寫程式 (Sequential File)
3. 比對輸出結果是否完全一致
4. 比對執行時間和資源消耗

**邊界條件測試**：
- 第一筆 CHR 無 Child
- 最後一筆 CHR 有多筆 Child
- 所有 CHR 都無 Child
- 單一 CHR 有大量 Child

### 7. 效能優化建議

**檔案區塊大小**：
```cobol
FD  CHRFILE
    BLOCK CONTAINS 0 RECORDS  ← 使用系統最佳區塊大小
    RECORD CONTAINS 475 CHARACTERS.
```

**緩衝區設定 (JCL)**：
```jcl
//CHRFILE DD DSN=資料集名稱,DISP=SHR,
//           BUFNO=20  ← 增加緩衝區數量
```

**避免不必要的 DISPLAY**：
- 開發階段可使用 DISPLAY 除錯
- 正式環境應註解掉以提升效能

### 8. 錯誤處理

**檔案開啟失敗**：
```cobol
OPEN INPUT CHRFILE CEDFILE.
IF FILE-STATUS-CHR NOT = '00'
    DISPLAY 'CHRFILE OPEN ERROR: ' FILE-STATUS-CHR
    MOVE 16 TO RETURN-CODE
    STOP RUN
END-IF.
```

**記錄長度不符**：
```cobol
READ CHRFILE AT END ...
    NOT AT END
        IF LENGTH OF CHRREC NOT = 475
            DISPLAY 'CHR RECORD LENGTH ERROR'
            MOVE 16 TO RETURN-CODE
            STOP RUN
        END-IF
END-READ.
```

### 9. 文件維護

**程式註解**：
```cobol
*========================================
* 程式名稱: DVMCRD01
* 說明: 金融卡事故查詢 (DVM 優化版)
* 輸入檔案:
*   - CHRFILE: CHR segment 資料
*   - CEDFILE: CHCED segment 資料
* 修改歷程:
*   2024-01-01 張三 從 TPSCRD01 改寫
*========================================
```

**變更記錄**：
- 記錄改寫日期和負責人
- 說明主要變更內容
- 保留原始程式名稱以便追溯

### 10. 版本控制

**建議做法**：
1. 保留原始 IMS 程式 (如 TPSCRD01)
2. 建立新的 DVM 程式 (如 DVMCRD01)
3. 兩個版本並行一段時間
4. 確認 DVM 版本穩定後再淘汰 IMS 版本

**命名慣例**：
- 原始程式：`TPSxxxx`
- DVM 程式：`DVMxxxx`
- 或使用版本號：`PROGxxx1` (IMS), `PROGxxx2` (DVM)

---

## 範例對照

### 完整程式結構對照

#### 原始程式 (TPSCRD01.cbl) - 關鍵部分

```cobol
IDENTIFICATION DIVISION.
PROGRAM-ID. TPSCRD01.

ENVIRONMENT DIVISION.
INPUT-OUTPUT SECTION.
FILE-CONTROL.
    SELECT DATEFL   ASSIGN TO S-DATEFL.
    SELECT ATMSTCP  ASSIGN TO S-ATMSTCP.

DATA DIVISION.
FILE SECTION.
FD  DATEFL ...
FD  ATMSTCP ...

WORKING-STORAGE SECTION.
COPY FUNCCODE SUPPRESS.
COPY CHSSA   SUPPRESS.
COPY CHRSEG  SUPPRESS.
COPY CHCEDSEG SUPPRESS.
COPY CMDWCVDT SUPPRESS.
COPY DBPCB  SUPPRESS.

LINKAGE SECTION.
01  IOPCB.  COPY DBPCB  SUPPRESS.
01  ACPCB.  COPY DBPCB  SUPPRESS.
01  CHPCB.  COPY DBPCB  SUPPRESS.

PROCEDURE DIVISION USING IOPCB ACPCB CHPCB.
MAIN-RTN.
    OPEN INPUT DATEFL OUTPUT ATMSTCP.
    
    *讀取 CHR
    CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.
    
    PERFORM UNTIL PSTATUS OF CHPCB = 'GB'
        IF PSTATUS OF CHPCB = SPACES OR 'FW'
            *處理 CHR
            
            *讀取 CHCED
            CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.
            
            PERFORM UNTIL PSTATUS OF CHPCB = 'GE'
                IF PSTATUS OF CHPCB = SPACES OR 'FW'
                    *處理 CHCED
                END-IF
                
                *讀取下一筆 CHCED
                CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.
            END-PERFORM
        END-IF
        
        *讀取下一筆 CHR
        CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.
    END-PERFORM.
    
    CALL 'CBLTDLI' USING SYNX IOPCB.
    CLOSE DATEFL ATMSTCP.
    STOP RUN.
```

#### 改寫程式 (DVMCRD01.cbl) - 關鍵部分

```cobol
IDENTIFICATION DIVISION.
PROGRAM-ID. DVMCRD01.

ENVIRONMENT DIVISION.
INPUT-OUTPUT SECTION.
FILE-CONTROL.
    SELECT DATEFL   ASSIGN TO S-DATEFL.
    SELECT ATMSTCP  ASSIGN TO S-ATMSTCP.
    SELECT CHRFILE  ASSIGN TO S-CHRFILE.    ← 新增
    SELECT CEDFILE  ASSIGN TO S-CEDFILE.    ← 新增

DATA DIVISION.
FILE SECTION.
FD  DATEFL ...
FD  ATMSTCP ...

FD  CHRFILE                                  ← 新增
    RECORD CONTAINS 475 CHARACTERS.
    01  CHRREC.
        05  CHR-REC        PIC X(439).
        05  CHR-KEY        PIC X(12).
        05  CHR-KEYH       PIC X(24).

FD  CEDFILE                                  ← 新增
    RECORD CONTAINS 94 CHARACTERS.
    01  CEDREC.
        05  CED-REC        PIC X(52).
        05  CED-KEY        PIC X(18).
        05  CED-KEYH       PIC X(24).

WORKING-STORAGE SECTION.
COPY FUNCCODE SUPPRESS.
COPY CHSSA   SUPPRESS.
COPY CHRSEG  SUPPRESS.
COPY CHCEDSEG SUPPRESS.
COPY CMDWCVDT SUPPRESS.
COPY DBPCB  SUPPRESS.

01 DVM-WORK.                                 ← 新增
   05 W1-CHR-ID        PIC X(24) VALUE LOW-VALUE.
   05 W1-CED-ID        PIC X(24) VALUE LOW-VALUE.

*LINKAGE SECTION.                            ← 註解掉
01  IOPCB.  COPY DBPCB  SUPPRESS.
01  ACPCB.  COPY DBPCB  SUPPRESS.
01  CHPCB.  COPY DBPCB  SUPPRESS.
LINKAGE SECTION.                             ← 空的 LINKAGE SECTION

PROCEDURE DIVISION.                          ← 不再接收參數
*PROCEDURE DIVISION USING IOPCB ACPCB CHPCB.

MAIN-RTN.
    OPEN INPUT DATEFL OUTPUT ATMSTCP.
    OPEN INPUT CHRFILE CEDFILE.              ← 新增
    
    *初始化：預讀第一筆 CEDFILE              ← 新增
    READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
        NOT AT END MOVE CED-KEYH TO W1-CED-ID
    END-READ.
    
    *讀取 CHR
    *CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.  ← 註解掉
    MOVE SPACES TO PSTATUS OF CHPCB.         ← 新增
    PERFORM 1000-GN-CHR.                     ← 新增
    
    PERFORM UNTIL PSTATUS OF CHPCB = 'GB'
        IF PSTATUS OF CHPCB = SPACES OR 'FW'
            *處理 CHR (邏輯不變)
            
            *讀取 CHCED
            *CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.  ← 註解掉
            PERFORM 1010-GNP-CED.            ← 新增
            
            PERFORM UNTIL PSTATUS OF CHPCB = 'GE'
                IF PSTATUS OF CHPCB = SPACES OR 'FW'
                    *處理 CHCED (邏輯不變)
                END-IF
                
                *讀取下一筆 CHCED
                *CALL 'CBLTDLI' USING GNP CHPCB CHCEDSEG CHCED-UQSSA.  ← 註解掉
                PERFORM 1010-GNP-CED.        ← 新增
            END-PERFORM
        END-IF
        
        *讀取下一筆 CHR
        *CALL 'CBLTDLI' USING GN CHPCB CHRSEG CHR-UQSSA.  ← 註解掉
        MOVE SPACES TO PSTATUS OF CHPCB.     ← 新增
        PERFORM 1000-GN-CHR.                 ← 新增
    END-PERFORM.
    
    *CALL 'CBLTDLI' USING SYNX IOPCB.       ← 註解掉
    CLOSE DATEFL ATMSTCP.
    CLOSE CHRFILE CEDFILE.                   ← 新增
    STOP RUN.

*新增 Paragraph                              ← 新增
1000-GN-CHR.
    READ CHRFILE AT END MOVE 'GB' TO PSTATUS OF CHPCB
        NOT AT END
            MOVE CHR-REC TO CHRSEG
            MOVE CHR-KEYH TO W1-CHR-ID
    END-READ.

*新增 Paragraph                              ← 新增
1010-GNP-CED.
    IF W1-CED-ID = W1-CHR-ID
        MOVE CED-REC TO CHCEDSEG
        MOVE SPACES TO PSTATUS OF CHPCB
        READ CEDFILE AT END MOVE HIGH-VALUE TO W1-CED-ID
            NOT AT END MOVE CED-KEYH TO W1-CED-ID
        END-READ
    ELSE
        MOVE 'GE' TO PSTATUS OF CHPCB
    END-IF.
```

### 關鍵差異總結

| 項目 | TPSCRD01 (IMS) | DVMCRD01 (Sequential) |
|------|----------------|----------------------|
| **檔案定義** | 無 (使用 IMS 資料庫) | CHRFILE + CEDFILE |
| **工作區** | 無額外欄位 | DVM-WORK (階層鍵暫存) |
| **LINKAGE SECTION** | 接收 3 個 PCB | 空的 (保留 PCB 定義) |
| **PROCEDURE DIVISION** | `USING IOPCB ACPCB CHPCB` | 無參數 |
| **Root 讀取** | `CBLTDLI GN` | `PERFORM 1000-GN-CHR` |
| **Child 讀取** | `CBLTDLI GNP` | `PERFORM 1010-GNP-CED` |
| **同步點** | `CBLTDLI SYNX` | (移除) |
| **檔案開啟** | 2 個檔案 | 4 個檔案 |
| **初始化** | 無 | 預讀第一筆 CEDFILE |
| **業務邏輯** | (原始邏輯) | (完全相同) |

---

## 附錄

### A. IMS DL/I 功能碼參考

| 功能碼 | 全名 | 用途 |
|-------|------|------|
| **GU** | Get Unique | 取得特定 segment |
| **GN** | Get Next | 取得下一個 segment |
| **GNP** | Get Next within Parent | 取得 Parent 下的下一個 Child |
| **GHU** | Get Hold Unique | 取得特定 segment (鎖定) |
| **GHN** | Get Hold Next | 取得下一個 segment (鎖定) |
| **GHNP** | Get Hold Next within Parent | 取得 Parent 下的下一個 Child (鎖定) |
| **ISRT** | Insert | 插入新 segment |
| **REPL** | Replace | 更新 segment |
| **DLET** | Delete | 刪除 segment |
| **CHKP** | Checkpoint | 設定檢查點 |
| **XRST** | Restart | 從檢查點重啟 |
| **SYNX** | Synchronization Point | 同步點 |

### B. IMS 狀態碼參考

| 狀態碼 | 意義 | 說明 |
|-------|------|------|
| **SPACES** | 成功 | 操作成功完成 |
| **FW** | Forward | 成功 (向前移動) |
| **GB** | End of Database | 已到達資料庫結尾 |
| **GE** | End of Children | 已到達 Parent 的最後一個 Child |
| **GK** | Segment Not Found | 找不到符合條件的 segment |
| **II** | Invalid Insert | 插入操作無效 |
| **DA** | No Delete Authority | 無刪除權限 |
| **DJ** | Duplicate Insert | 重複插入 |

### C. 檔案記錄長度計算

**CHRFILE (475 bytes)**：
```
CHR-REC  (資料區)     : 439 bytes
CHR-KEY  (主鍵)       :  12 bytes
CHR-KEYH (階層鍵)     :  24 bytes
                      ─────────
總計                  : 475 bytes
```

**CEDFILE (94 bytes)**：
```
CED-REC  (資料區)     :  52 bytes
CED-KEY  (主鍵)       :  18 bytes
CED-KEYH (階層鍵)     :  24 bytes
                      ─────────
總計                  :  94 bytes
```

### D. JCL 範例

**執行 DVM 程式的 JCL**：

```jcl
//DVMCRD01 JOB (ACCT),'DVM CARD QUERY',CLASS=A,MSGCLASS=X
//STEP1    EXEC PGM=DVMCRD01
//STEPLIB  DD DSN=LOAD.LIBRARY,DISP=SHR
//DATEFL   DD DSN=INPUT.DATEFL,DISP=SHR
//CHRFILE  DD DSN=DVM.CHRFILE,DISP=SHR
//CEDFILE  DD DSN=DVM.CEDFILE,DISP=SHR
//ATMSTCP  DD DSN=OUTPUT.ATMSTCP,DISP=(NEW,CATLG,DELETE),
//            SPACE=(CYL,(10,5),RLSE),
//            DCB=(RECFM=FB,LRECL=80,BLKSIZE=0)
//SYSOUT   DD SYSOUT=*
```

**DVM 掃檔作業 JCL** (產生 Sequential Files)：

```jcl
//DVMSCAN  JOB (ACCT),'DVM SCAN',CLASS=A,MSGCLASS=X
//STEP1    EXEC PGM=DVMSCAN
//STEPLIB  DD DSN=DVM.LOADLIB,DISP=SHR
//IMSDB    DD DSN=IMS.DATABASE,DISP=SHR
//CHRFILE  DD DSN=DVM.CHRFILE,DISP=(NEW,CATLG,DELETE),
//            SPACE=(CYL,(100,10),RLSE),
//            DCB=(RECFM=FB,LRECL=475,BLKSIZE=0)
//CEDFILE  DD DSN=DVM.CEDFILE,DISP=(NEW,CATLG,DELETE),
//            SPACE=(CYL,(200,20),RLSE),
//            DCB=(RECFM=FB,LRECL=94,BLKSIZE=0)
//SYSOUT   DD SYSOUT=*
```

### E. 常見問題 (FAQ)

**Q1: 如果 IMS 資料庫有 3 層以上的階層結構怎麼辦？**

A: 需要為每一層建立對應的 Sequential File，並使用多個階層鍵欄位。例如：
```
Root (CHR)
 └── Level 1 (CHCED)
      └── Level 2 (DETAIL)
```
需要 3 個檔案和 2 組階層鍵比對邏輯。

**Q2: 如何處理 SSA (Segment Search Arguments)？**

A: DVM 優化主要適用於循序讀取。如果原程式使用複雜的 SSA 查詢，可能需要：
- 在 Sequential File 中預先篩選資料
- 在 COBOL 程式中增加額外的判斷邏輯
- 考慮是否適合使用 DVM 優化

**Q3: DVM 檔案多久需要更新一次？**

A: 取決於業務需求：
- 日報表：每日掃檔一次
- 月報表：每月掃檔一次
- 即時性要求高的程式不適合使用 DVM

**Q4: 如何確保 DVM 檔案與 IMS 資料庫同步？**

A: 建議做法：
- 建立定期掃檔排程
- 在掃檔作業中記錄時間戳記
- 在報表中註明資料截止時間
- 關鍵交易仍使用 IMS 即時存取

**Q5: 改寫後效能提升多少？**

A: 實際效益因環境而異，一般可預期：
- CPU 使用率降低 30-50%
- 執行時間縮短 20-40%
- IMS 子系統負載降低 50-70%
- 具體數據需透過實際測試驗證

**Q6: 是否需要修改 COPY 成員？**

A: 通常不需要。COPY 成員定義的資料結構保持不變，只是資料來源從 IMS 改為 Sequential File。

**Q7: 如何處理錯誤和異常情況？**

A: 建議增加以下錯誤處理：
- 檔案開啟失敗檢查
- 記錄長度驗證
- 階層鍵完整性檢查
- 詳細的錯誤訊息記錄

### F. 參考資源

**IBM 官方文件**：
- IBM IMS DL/I Programming Guide
- IBM Data Virtualization Manager Documentation
- COBOL Programming Guide

**內部文件**：
- DVM 實施標準作業程序
- COBOL 程式開發規範
- 批次作業排程指南

**聯絡窗口**：
- DVM 技術支援：[聯絡資訊]
- COBOL 開發團隊：[聯絡資訊]
- IMS 資料庫管理：[聯絡資訊]

---

## 版本歷程

| 版本 | 日期 | 修改者 | 修改內容 |
|------|------|--------|---------|
| 1.0 | 2024-01-01 | 文件撰寫團隊 | 初版發布 |

---

**文件結束**