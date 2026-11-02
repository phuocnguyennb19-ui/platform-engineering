# 0002 — Value theo môi trường, không có lớp chung

- Status: Accepted
- Date: 2026-10-21

## Bối cảnh

Trước đây value của một tool platform là hai lớp: file chung cho mọi môi trường cộng file ghi đè của
từng môi trường. Muốn biết prod thật sự nhận gì phải ghép hai file trong đầu. Các môi trường sẽ
khác nhau nhiều hơn khi có môi trường thật.

## Quyết định

- `environments/<dev|staging|prod>/kubernetes/` là folder **đầy đủ** của môi trường: `state.yaml`, `cluster/`,
  `namespace/`, `network/`, `tools|ingress|monitoring/<tool>/`, `app-values.yaml.gotmpl`,
  `secrets.enc.yaml`.
- Mỗi file value là toàn bộ value của tool ở môi trường đó, ghép thẳng trên mặc định của chart —
  giống `applications/<app>/k8s/<env>/values.yaml` của app.
- Thứ không phải value đặt ngoài: repo chart + `helmDefaults` (`kubernetes/repositories.yaml`), công cụ
  metadata cluster (`scripts/cluster/`).

Chuyển đổi được kiểm chứng: value đã gộp của 32 helmfile × 3 môi trường và render của mọi app giống
hệt trước khi chuyển.

## Hệ quả

- Được: đọc một file là biết môi trường nhận gì; review prod chỉ nhìn `prod/`.
- Mất: một thay đổi cho mọi môi trường phải sửa 3 file. Review bằng diff giữa `dev/`, `staging/`, `prod/`
  để các key không phụ thuộc môi trường không lệch nhau ngoài ý muốn.
