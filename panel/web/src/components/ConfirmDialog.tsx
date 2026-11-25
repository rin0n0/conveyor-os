import { useEffect, useId, useRef } from "react";

interface ConfirmDialogProps {
  open: boolean;
  title: string;
  message: string;
  confirmLabel?: string;
  danger?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

export function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel = "Подтвердить",
  danger = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const titleId = useId();

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;

    if (open && !dialog.open) {
      dialog.showModal();
    } else if (!open && dialog.open) {
      dialog.close();
    }
  }, [open]);

  const handleClose = () => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    const val = dialog.returnValue;
    dialog.returnValue = "";
    if (val === "confirm") {
      onConfirm();
    } else {
      onCancel();
    }
  };

  return (
    <dialog
      ref={dialogRef}
      className="confirm-dialog"
      aria-labelledby={titleId}
      onClose={handleClose}
    >
      <h1 id={titleId} className="dialog-title">
        {title}
      </h1>
      <p className="dialog-body">{message}</p>
      <form method="dialog" className="dialog-actions">
        <button type="submit" value="cancel" className="btn" autoFocus>
          Отмена
        </button>
        <button
          type="submit"
          value="confirm"
          className={`btn ${danger ? "danger" : "primary"}`}
        >
          {confirmLabel}
        </button>
      </form>
    </dialog>
  );
}
