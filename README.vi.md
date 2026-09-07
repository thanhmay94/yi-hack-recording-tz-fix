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

Không chỉ `system.sh` khởi động `mp4record`. Còn có:

- `watch_process` của Yi, tự khởi động lại nếu thấy nó chết
  (thừa hưởng `TZ=GMT+07:00` từ `system.sh`)
- CGI `camera_settings.sh?switch_on=yes`, chạy mỗi lần bật lại ghi hình — từ
  app điện thoại, từ lịch bật/tắt, hoặc từ script của chính bạn. Nó thừa hưởng
  `TZ` từ `httpd`, tức nội dung `/home/yi-hack/etc/TZ`.

Nếu hai bản cùng ra một offset, chúng ghi vào **cùng một thư mục** và đè lên file
của nhau. Kết quả là file `.mp4` đủ kích thước, mở được bình thường, nhưng chỉ
giải mã được **20-60% số frame** mà nó khai báo.

Triệu chứng này rất dễ bị chẩn đoán nhầm thành hỏng chip mã hoá. Không phải —
đó là hai tiến trình cùng ghi một chỗ. Kiểm tra bằng:

```sh
ps | grep '[m]p4record'
```

Ra khác một dòng là có vấn đề.

Vì vậy `sua_mp4record.sh` còn được đăng ký cron mỗi 5 phút với tham số `--canh`:
nếu đang đúng (một bản, đúng `TZ`) thì thoát ngay không đụng đến việc ghi hình,
chỉ dọn khi thật sự sai.

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
