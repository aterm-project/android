#define _GNU_SOURCE

#ifdef PAM_SERVICE_WRITER

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "expected service-file path and contents\n");
    return 2;
  }

  const char *path = argv[1];
  const char *contents = argv[2];
  int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (descriptor < 0) {
    int open_error = errno;
    perror("exclusive PAM service creation failed");
    return open_error == EEXIST ? 3 : 4;
  }

  if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0) {
    perror("could not set PAM service mode");
    close(descriptor);
    unlink(path);
    return 5;
  }

  size_t length = strlen(contents);
  size_t offset = 0;
  while (offset < length) {
    ssize_t written = write(descriptor, contents + offset, length - offset);
    if (written < 0 && errno == EINTR) {
      continue;
    }
    if (written <= 0) {
      perror("could not write PAM service");
      close(descriptor);
      unlink(path);
      return 6;
    }
    offset += (size_t)written;
  }

  if (fsync(descriptor) != 0) {
    int sync_error = errno;
    close(descriptor);
    errno = sync_error;
    perror("could not flush PAM service");
    unlink(path);
    return 7;
  }
  if (close(descriptor) != 0) {
    perror("could not close PAM service");
    unlink(path);
    return 7;
  }
  return 0;
}

#else

#include <security/pam_appl.h>
#include <security/pam_modules.h>

#include <stdlib.h>
#include <string.h>

#ifndef ATERMIUS_PAM_EXPECTED_CODE
#define ATERMIUS_PAM_EXPECTED_CODE "atermius-kbdint-code"
#endif
#ifndef ATERMIUS_PAM_EXPECTED_OTP
#define ATERMIUS_PAM_EXPECTED_OTP "620914"
#endif

static const char expected_code[] = ATERMIUS_PAM_EXPECTED_CODE;
static const char expected_otp[] = ATERMIUS_PAM_EXPECTED_OTP;

static void clear_response(char *response) {
  if (response == NULL) {
    return;
  }

  volatile char *cursor = (volatile char *)response;
  size_t length = strlen(response);
  while (length-- > 0) {
    *cursor++ = '\0';
  }
  free(response);
}

int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc,
                        const char **argv) {
  (void)flags;
  (void)argc;
  (void)argv;

  const struct pam_conv *conversation = NULL;
  int result = pam_get_item(pamh, PAM_CONV, (const void **)&conversation);
  if (result != PAM_SUCCESS || conversation == NULL ||
      conversation->conv == NULL) {
    return PAM_SYSTEM_ERR;
  }

  const struct pam_message code_prompt = {
      .msg_style = PAM_PROMPT_ECHO_ON,
      .msg = "Account code:",
  };
  const struct pam_message otp_prompt = {
      .msg_style = PAM_PROMPT_ECHO_OFF,
      .msg = "One-time code:",
  };
  const struct pam_message *messages[] = {&code_prompt, &otp_prompt};
  struct pam_response *responses = NULL;
  result = conversation->conv(2, messages, &responses,
                              conversation->appdata_ptr);

  int accepted = result == PAM_SUCCESS && responses != NULL &&
                 responses[0].resp != NULL && responses[1].resp != NULL &&
                 strcmp(responses[0].resp, expected_code) == 0 &&
                 strcmp(responses[1].resp, expected_otp) == 0;

  if (responses != NULL) {
    clear_response(responses[0].resp);
    clear_response(responses[1].resp);
    free(responses);
  }

  return accepted ? PAM_SUCCESS : PAM_AUTH_ERR;
}

int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc,
                   const char **argv) {
  (void)pamh;
  (void)flags;
  (void)argc;
  (void)argv;
  return PAM_SUCCESS;
}

#endif
