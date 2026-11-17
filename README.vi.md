# Sửa lỗi tên thư mục ghi hình sai giờ trên camera Yi-hack

Camera Yi chạy [yi-hack-MStar](https://github.com/roleoroleo/yi-hack-MStar) lưu
video vào `/tmp/sd/record/<YYYY>Y<MM>M<DD>D<HH>H/<MM>M<SS>S.mp4`. **Tên thư mục
ra giờ UTC** trong khi dấu thời gian chèn trong khung hình lại đúng giờ địa
phương. Mọi thứ suy ra giờ quay từ tên thư mục đều bị lệch đúng bằng offset múi
giờ của bạn.

Repo này giải thích nguyên nhân và sửa nó mà không làm hỏng dấu thời gian trên
khung hình.

Kèm theo một lỗi thứ hai cũng được ghi lại ở đây: **file .mp4 bị cụt trông y hệt
triệu chứng hỏng phần cứng** nhưng thực ra không phải.

## Hai đồng hồ

Đây là chìa khoá. Hai thứ lấy giờ từ hai nguồn khác nhau nhưng dùng chung một
offset:

```
Dấu thời gian trên khung hình (OSD) = múi giờ hệ thống (/etc/localtime) + tz_offset_osd
Tên thư mục ghi hình                = TZ riêng của mp4record            + tz_offset_osd
```

`tz_offset_osd` là một số nguyên (giây) ghi trong file bộ nhớ chia sẻ
`/tmp/mmap.info`, tại địa chỉ `0x4F4` với model `y203c` (xem bảng địa chỉ theo
model trong
[`set_tz_offset.c`](https://github.com/roleoroleo/yi-hack-MStar/blob/master/src/set_tz_offset/set_tz_offset/set_tz_offset.c)).
`system.sh` đặt nó bằng offset múi giờ của bạn ở mỗi lần khởi động. Nó nằm trong
`/tmp` (RAM) nên không sống qua reboot.

## Nguyên nhân

`system.sh` khởi động `mp4record` như sau:

```sh
export TZP=`TZ=$TZ_TMP date +%z`      # "+0700"
export TZP=${TZP:0:3}:${TZP:3:2}      # "+07:00"
export TZ=GMT$TZP                     # "GMT+07:00"
./mp4record
```

Theo chuẩn POSIX, `GMT+07:00` nghĩa là 7 tiếng về phía **Tây**, tức `UTC-7` —
ngược dấu với ý định người viết. Thay vào công thức (ví dụ múi giờ UTC+7, tức
`tz_offset_osd = 25200`):

```
Thư mục = (-7) + (+7) = 0    ->  ra giờ UTC        (sai)
OSD     =   0  + (+7) = +7   ->  ra giờ địa phương (may mà đúng)
```

Hai cái sai triệt tiêu nhau ở OSD nhưng không triệt tiêu ở tên thư mục.

## Cách sửa

Khởi động lại `mp4record` với `TZ=UTC0` và **giữ nguyên `tz_offset_osd`**:

```
Thư mục = 0 + (+7) = +7   ->  giờ địa phương ✓
OSD     = 0 + (+7) = +7   ->  không đổi      ✓
```

`sua_mp4record.sh` làm việc đó: đợi `system.sh` khởi động xong bản lỗi của nó,
giết sạch mọi `mp4record`, rồi khởi động lại đúng một bản với `TZ=UTC0`. Nó được
gọi từ `/tmp/sd/yi-hack/startup.sh` — file mà `system.sh` tự chạy ở cuối quá
trình khởi động. Mọi thứ nằm trên thẻ SD nên sống qua cả reboot lẫn nâng cấp
firmware.

> **Đừng** sửa bằng cách đặt `tz_offset_osd = 0` rồi dùng `TZ=ICT-7`. Cách đó
> cũng cho tên thư mục đúng, nhưng nó kéo OSD lệch theo và dấu thời gian trên
> khung hình sẽ thành giờ UTC — tệ hơn nhiều, vì khác với tên thư mục, cái đó
> không sửa lại được sau khi đã quay.

## Bẫy 1: nhiều tiến trình `mp4record` làm hỏng video

CGI `service.sh?name=mp4record&action=start` chạy thẳng `./mp4record &` mà
**không kiểm tra gì cả** — không hỏi đã có tiến trình nào chưa, không giết cái
cũ. Bản gốc yi-hack-MStar 0.5.7 dòng 466-474, master hôm nay vẫn vậy. Gọi n lần
ra n tiến trình. Mà `system.sh` đã bật sẵn một cái lúc khởi động, nên ngay lần
gọi đầu tiên đã thành hai.

Hỏi trước cũng không được. `action=status` chính là hàm `ps_program()`:

```sh
ps | grep $1 | grep -v grep | grep -c ^
```

Dòng lệnh của chính tiến trình CGI đang hỏi có chứa `$1`, nên nó khớp với chính
mình. Hỏi status của một chương trình không hề tồn tại cũng ra `started`. Cách
duy nhất chắc chắn là `stop` (tức `killall`, gọi bao nhiêu lần cũng vậy) rồi mới
`start`.

Mọi thứ bật lại ghi hình đều đi qua đây: app Yi trên điện thoại, lịch bật/tắt,
công cụ của chính bạn.

**Vì sao phải đúng một.** Mọi `mp4record` đều ghi qua *cùng một file trung gian*
`/tmp/sd/record/tmp.mp4.tmp`, xong clip mới đổi tên vào thư mục giờ. Đường dẫn đó
giống hệt nhau bất kể mỗi tiến trình mang `TZ` gì hay nhắm vào thư mục nào. Hai
tiến trình là hai luồng H.264 xen vào nhau trong một file: đủ kích thước, mở được
bình thường, nhưng chỉ giải mã được **20-60% số frame** mà nó khai báo. Trông y
hệt hỏng chip mã hoá. Không phải.

Kiểm tra bằng:

```sh
ps | grep '[m]p4record'
```

Ra khác một dòng là có vấn đề.

Vì vậy `sua_mp4record.sh` còn được đăng ký cron với tham số `--canh`: nếu đang
đúng (một bản, đúng `TZ`) thì thoát ngay không đụng đến việc ghi hình, chỉ dọn
khi thật sự sai. Mỗi lần chạy tốn khoảng 0,4 giây, nên đặt mỗi phút là hợp lý
với camera có bật tắt trong ngày.

Hai nghi phạm hoá ra vô can, ghi lại để bạn khỏi mất công tìm: `watch_process`
của Yi không hề chạy trên các camera này, còn
`camera_settings.sh?switch_on=yes` chỉ gọi `ipc_cmd -t on` chứ không tự khởi
động bản ghi hình nào.

## Bẫy 2: `/etc/localtime` nằm trên thân máy, không nằm trên thẻ SD

Nếu có `/etc/TZ` và `/etc/localtime` thì múi giờ hệ thống là giờ địa phương chứ
không phải UTC, và công thức đầu thành `OSD = (+7) + (+7) = +14`.

Hai file này nằm trên bộ nhớ trong (jffs2) nên **đi theo thân máy** khi bạn tráo
thẻ SD giữa các camera. Nếu từng tráo phần cứng, có thể một máy có còn máy kia
không — cùng một cấu hình mà hai máy chạy ra kết quả khác nhau.

Kiểm tra trước khi vá:

```sh
date
```

Ra `UTC` là đúng. Ra giờ địa phương thì phải gỡ `/etc/TZ` và `/etc/localtime`
(nhớ sao lưu), nếu không OSD sẽ lệch thêm một lần offset nữa. Script cài đặt sẽ
hỏi bạn việc này.

## Bẫy 3: bản upload Google Drive chậm hẳn 7 tiếng

Chỉ liên quan nếu bạn dùng add-on Google Drive của roleoroleo
(`/tmp/sd/yi-hack/gdrive/`).

`GDriveUploader` đổi tên thư mục ngược lại thành mốc thời gian bằng `date -d`,
mà `date` lấy theo đồng hồ hệ thống — vốn là UTC. Từ khi tên thư mục mang giờ
địa phương, nó nhìn thư mục nào cũng thấy nằm ở tương lai, nên chờ đủ một lần
offset múi giờ mới chuyển sang giờ kế tiếp. Kết quả là upload luôn chậm đúng
bằng offset đó. Không mất dữ liệu, chỉ trễ.

Cho uploader dùng chung đồng hồ với tên thư mục, trong
`/tmp/sd/yi-hack/startup.sh`:

```sh
GDRIVE_TZ=$(cat /home/yi-hack/etc/TZ 2>/dev/null)
TZ="$GDRIVE_TZ" sh /tmp/sd/yi-hack/gdrive/GDriveUploader
TZ="$GDRIVE_TZ" sh /tmp/sd/yi-hack/gdrive/GDriveAutoremover
```

`restart_gdrive.sh` áp dụng ngay cho camera đang chạy, không cần reboot.

Ba điều phải biết trước khi làm:

- **`start_time` / `finish_time`** ở đầu file `GDriveUploader` được đọc theo
  đồng hồ mà tiến trình đang có. Nếu bạn có đặt khung giờ upload thì từ nay nó
  mang nghĩa giờ địa phương chứ không phải UTC — khung `01:00`–`07:00` vốn đang
  chạy thật vào 08:00–14:00 giờ địa phương sẽ dời về đúng 01:00–07:00. Kiểm tra
  lại xem còn đúng ý bạn không.
- **`get_next_dir()` chỉ đi tới** (`[ "$current_dir" \< "$n" ]`). Nếu con trỏ
  trong `gdrive_folder.index` lỡ vượt lên trước các thư mục thật — do thử
  nghiệm đồng hồ, do đổi tên thư mục — thì mọi giờ ở giữa bị bỏ qua vĩnh viễn.
  Dùng `restart_gdrive.sh <THU_MUC> <ID_DRIVE>` để kéo con trỏ lùi lại.
- **Phải khởi động với đúng biến môi trường.** `system.sh` (dòng 53-54) đưa
  `curl` đi kèm vào `PATH` và thư viện của nó vào `LD_LIBRARY_PATH` trước khi
  gọi `startup.sh`. Nếu bạn chạy uploader từ một phiên SSH trắng, mọi lần upload
  đều hỏng với `libssl.so.1.1: cannot open shared object file` — ghi lặng lẽ vào
  `log/GDriveUploader.log` trong khi tiến trình vẫn quay vòng như không có gì.

## Bẫy 4: dòng cron của bạn không bao giờ chạy

`sua_mp4record.sh --canh` được đăng ký dưới dạng cron. Trên camera nguyên bản,
dòng cron đó **không chạy lần nào**, mà không có gì báo cho bạn biết.

`busybox crond` đọc crontab **đúng một lần lúc nó khởi động**, sau đó không quét
lại nữa. `system.sh` bật crond ở dòng 385, rồi mới gọi
`/tmp/sd/yi-hack/startup.sh` ở dòng 395 — tức là sau. Nên mọi dòng cron ghi từ
`startup.sh` đều rơi vào một file mà crond đã đọc xong từ trước.

Đo trên y203c: thêm một dòng vào `/var/spool/cron/crontabs/root`, chờ 80 giây,
không có gì chạy. Khởi động lại crond thì nó nổ ngay phút kế tiếp.

Chuyện này ảnh hưởng tới mọi thứ bạn hẹn giờ từ `startup.sh`, không riêng bản vá
này. `/var/spool` lại nằm trên tmpfs, nên sau mỗi lần reboot crontab mất sạch và
được `startup.sh` ghi lại — vào một crond sẽ không đọc nó nữa.

Vì vậy `startup.sh` phải khởi động lại crond sau khi ghi xong crontab:

```sh
for p in $(ps | grep '[c]rond' | awk '{print $1}'); do kill "$p" 2>/dev/null; done
sleep 2
/usr/sbin/crond -c /var/spool/cron/crontabs/
```

`deploy.py` tự ghi đoạn này. Muốn kiểm tra một camera đang chạy:

```sh
echo '* * * * * date >> /tmp/moc.txt' >> /var/spool/cron/crontabs/root
sleep 80; cat /tmp/moc.txt      # trống nghĩa là crond không đọc crontab của bạn
```

## Bẫy 5: giết `mp4record` sai lúc làm camera ngừng ghi đến tận lần reboot sau

`mp4record` đọc khung hình từ một bộ đệm dùng chung. Bộ đệm này được canh bằng
semaphore `/dev/sem.fshare_read_lock`, là một file 16 byte trên tmpfs, trong đó
byte 0 cho biết trạng thái: 1 là rảnh, 0 là đang có tiến trình giữ. Nếu giết
`mp4record` đúng lúc nó đang giữ semaphore, giá trị sẽ đứng ở 0 mãi. Mọi
`mp4record` chạy sau đó đều treo ở `sem_wait`, ngay sau dòng log `fshare_open ok`.
Lúc đó tiến trình vẫn còn, `SWITCH_ON` vẫn là `yes`, RTSP vẫn xem được, nhưng
không có file nào được ghi. Trong `/tmp/log.txt`, dòng `rcd may crashed` lặp lại
hàng trăm lần, còn `file begin record` thì không xuất hiện. Một camera của chúng
tôi đã mất 3,5 ngày video như vậy, vì chỉ reboot mới xoá được semaphore.

Lỗi hiếm gặp vì semaphore chỉ bị giữ trong vài micro giây: đọc 300 lần trong 10
giây trên camera đang ghi, không lần nào thấy 0. Nhưng bản vá này giết
`mp4record` mỗi khi có bản ghi chạy trùng hoặc chạy sai TZ, tức vài lần mỗi ngày.
Cộng dồn qua nhiều tháng và nhiều camera thì sớm muộn cũng trúng đúng lúc.

`sua_mp4record.sh` chống lỗi này bằng hai lớp:

- **Phòng:** đóng băng tiến trình bằng `SIGSTOP`, đọc semaphore, và chỉ gửi
  `SIGTERM` khi semaphore đang rảnh. Tiến trình đang bị đóng băng thì không thể
  đang giữ semaphore. Dùng `SIGTERM` chứ không dùng `SIGKILL`, để `mp4record` còn
  kịp lưu phút video đang ghi dở.
- **Chữa:** mỗi lần chạy `--canh` (mỗi phút), nếu semaphore đọc ra 0 liên tục 6
  lần trong khoảng 2,5 giây, script ghi lại giá trị 1 rồi khởi động lại bộ ghi.
  Cách này không cần reboot. Đã thử bằng cách tự ghi 0 vào semaphore: camera ngừng
  ghi, đến lượt cron kế tiếp thì ghi lại, mất chưa đến một phút video.

Kiểm tra tay trên một camera đang bật ghi:

```sh
dd if=/dev/sem.fshare_read_lock bs=1 count=1 2>/dev/null | hexdump -C   # 01 là bình thường
```

## Cài đặt

Cần Python 3 và `paramiko` trên PC (`pip install paramiko`), và camera đã bật
SSH (mặc định yi-hack: user `root`, không mật khẩu).

```bash
python deploy.py 192.168.1.99
```

Trên Windows có thể click đúp `run_deploy.bat`, nó chỉ hỏi IP.

Sau đó reboot camera:

```
http://<ip-camera>/cgi-bin/reboot.sh
```

## Kiểm tra lại

Khoảng 2 phút sau khi reboot:

```sh
date                       # phải ra UTC
date -u                    # giờ UTC thật
ls /tmp/sd/record | tail   # thư mục mới nhất phải khớp giờ ĐỊA PHƯƠNG
ps | grep '[m]p4record'    # đúng một tiến trình
```

Rồi tải file `.mp4` mới nhất về, xem dấu thời gian trên khung hình có khớp tên
thư mục + tên file không. Cả ba phải trùng nhau.

## Gỡ bỏ

Xoá dòng gọi `sua_mp4record.sh` trong `/tmp/sd/yi-hack/startup.sh`, xoá dòng cron
trong `/var/spool/cron/crontabs/root`, rồi reboot.

## Phạm vi đã kiểm chứng

Model `y203c`, firmware app `4.5.0.0C_201910080934`, yi-hack-MStar `0.5.7`, múi
giờ UTC+7. Công thức không phụ thuộc múi giờ; `TZ=UTC0` là giá trị đúng cho mọi
múi giờ, vì bản vá dựa vào `tz_offset_osd` (thứ mà `system.sh` vốn đã đặt đúng
theo múi giờ của bạn) chứ không hard-code offset nào.

Camera chạy **yi-hack-v5** là mã nguồn khác, không dính lỗi này — cứ kiểm tra
`date` trước.

## Giấy phép

MIT
