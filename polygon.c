#define _GNU_SOURCE
////////////////////////////////////////
/// 640x480 version! 16-bit color
/// This code will segfault the original
/// DE1 computer
/// compile with
/// gcc graphics_video_16bit.c -o gr -O2 -lm
///////////////////////////////////////
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <math.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>

// #include "address_map_arm_brl4.h"

// video display
#define SDRAM_BASE 0xC0000000
#define SDRAM_END 0xC3FFFFFF
#define SDRAM_SPAN 0x04000000
// characters
#define FPGA_CHAR_BASE 0xC9000000
#define FPGA_CHAR_END 0xC9001FFF
#define FPGA_CHAR_SPAN 0x00002000
/* Cyclone V FPGA devices */
#define HW_REGS_BASE 0xC0000000
#define HW_REGS_SPAN 0x05000000

// Image selection
char target_image_file[64] = "mona_lisa.txt";

// for keyboard input
char user_input_buffer[64];

// graphics primitives
void VGA_text(int, int, char *);
void VGA_text_clear();
void VGA_box(int, int, int, int, short);
void VGA_rect(int, int, int, int, short);
void VGA_line(int, int, int, int, short);
void VGA_Vline(int, int, int, short);
void VGA_Hline(int, int, int, short);
void VGA_disc(int, int, int, short);
void VGA_circle(int, int, int, int);

// 16-bit primary colors
#define red (0 + (0 << 5) + (31 << 11))
#define dark_red (0 + (0 << 5) + (15 << 11))
#define green (0 + (63 << 5) + (0 << 11))
#define dark_green (0 + (31 << 5) + (0 << 11))
#define blue (31 + (0 << 5) + (0 << 11))
#define dark_blue (15 + (0 << 5) + (0 << 11))
#define yellow (0 + (63 << 5) + (31 << 11))
#define cyan (31 + (63 << 5) + (0 << 11))
#define magenta (31 + (0 << 5) + (31 << 11))
#define black (0x0000)
#define gray (15 + (31 << 5) + (51 << 11))
#define white (0xffff)

int colors[] = {red, dark_red, green, dark_green, blue, dark_blue,
                yellow, cyan, magenta, gray, black, white};

// pixel macro
#define VGA_PIXEL(x, y, color)                                                 \
    do                                                                         \
    {                                                                          \
        int *pixel_ptr;                                                        \
        pixel_ptr = (int *)((char *)vga_pixel_ptr + (((y) * 640 + (x)) << 1)); \
        *(short *)pixel_ptr = (color);                                         \
    } while (0)

#define SWAP(X, Y)    \
    do                \
    {                 \
        int temp = X; \
        X = Y;        \
        Y = temp;     \
    } while (0)

// the light weight buss base
void *h2p_lw_virtual_base;

// pixel buffer
volatile unsigned int *vga_pixel_ptr = NULL;
void *vga_pixel_virtual_base;

// character buffer
volatile unsigned int *vga_char_ptr = NULL;
void *vga_char_virtual_base;

// /dev/mem file id
int fd;

// Avalon instantiation variables
volatile signed int *poly_x_1 = NULL;
volatile signed int *poly_x_2 = NULL;
volatile signed int *poly_x_3 = NULL;
volatile signed int *poly_x_4 = NULL;
volatile signed int *poly_y_1 = NULL;
volatile signed int *poly_y_2 = NULL;
volatile signed int *poly_y_3 = NULL;
volatile signed int *poly_y_4 = NULL;

volatile unsigned int *poly_clr = NULL;
volatile float *poly_sse = NULL;

volatile unsigned int *in_valid = NULL;
volatile unsigned int *out_valid = NULL;
volatile unsigned int *out_ack = NULL;
volatile float *poly_size_weight = NULL;

volatile signed int *image_stream_rgb = NULL;
volatile unsigned int *image_stream_x = NULL;
volatile unsigned int *image_stream_y = NULL;
volatile unsigned int *write_en = NULL;

int global_counter = 0;

// for 5-6-5 encoding
#define EXTRACT_RED_16(pixel) (((pixel) >> 11) & 0x1F)
#define EXTRACT_GREEN_16(pixel) (((pixel) >> 5) & 0x3F)
#define EXTRACT_BLUE_16(pixel) ((pixel) & 0x1F)

// for 3-3-2 encoding
#define EXTRACT_RED_8(pixel) (((pixel) >> 5) & 0x7)
#define EXTRACT_GREEN_8(pixel) (((pixel) >> 2) & 0x7)
#define EXTRACT_BLUE_8(pixel) ((pixel) & 0x3)

#define GET_R_255(pixel) (((((uint16_t)(pixel) >> 11) & 0x1F) * 255) / 31)
#define GET_G_255(pixel) (((((uint16_t)(pixel) >> 5) & 0x3F) * 255) / 63)
#define GET_B_255(pixel) ((((uint16_t)(pixel) & 0x1F) * 255) / 31)

#define ORIG_IMG_WIDTH 330
#define ORIG_IMG_HEIGHT 492
#define SCREEN_IMG_WIDTH 320
#define SCREEN_IMG_HEIGHT 480
#define MAX_WIDTH 640
#define MAX_HEIGHT 480
#define X_OFFSET_IMG (ORIG_IMG_WIDTH - MAX_WIDTH) / 2
#define Y_OFFSET_IMG -(ORIG_IMG_WIDTH - MAX_WIDTH) / 2
#define IMG_LEFT (320 - 0.5 * SCREEN_IMG_WIDTH)

// Program parameters
#define N_PIXEL_SSE 1
#define MIN_SSE 5000
// TODO approx sqrt
// TODO less iterations or decreasing iterations
// Also try more iterations and see quality bc we can aford it with the FPGA
// and see if can jump more somehow

// Define OFFSETS for Avalon parameters
#define POLY_X_1_OFFSET 0x04000010
#define POLY_X_2_OFFSET 0x04000020
#define POLY_X_3_OFFSET 0x04000030
#define POLY_X_4_OFFSET 0x04000040
#define POLY_Y_1_OFFSET 0x04000050
#define POLY_Y_2_OFFSET 0x04000060
#define POLY_Y_3_OFFSET 0x04000070
#define POLY_Y_4_OFFSET 0x04000080
#define POLY_COLOR_OFFSET 0x04000090
#define SIZE_WEIGHT_OFFSET 0x040000A0
#define IN_VALID_OFFSET 0x040000B0
#define OUT_VALID_OFFSET 0x040000C0
#define OUT_ACK_OFFSET 0x040000D0
#define POLY_SSE_OFFSET 0x040000E0

#define IMAGE_STREAM_RGB_OFFSET 0x040000F0
#define IMAGE_STREAM_X_OFFSET 0x04000100
#define IMAGE_STREAM_Y_OFFSET 0x04000110
#define WRITE_EN_OFFSET 0x04000120
// end program parameters

// begin program variables
int xform_image[MAX_WIDTH * MAX_HEIGHT];
int xform_image_raw[SCREEN_IMG_WIDTH * SCREEN_IMG_HEIGHT];

int good_count = 0;
float total_sse = 0;
int NUM_POLYGONS = 1000;
int NUM_VERTICES = 3;
int NUM_ITERATIONS = 100;

float start_weight;
float end_weight;

float start_bounding_box; // 5 before, 100 too much
float end_bounding_box;   // 5

float start_mutate_delta;
float end_mutate_delta;

float start_mutate_shift;
float end_mutate_shift;

float start_alpha;
float end_alpha;

char time_string[50];

bool reset_requested = false;

typedef enum
{
    NORMAL,
    RED_SHIFT,
    GREEN_SHIFT,
    BLUE_SHIFT,
    HALLUCINATE,
    PAINT
} RenderMode;

// Global variable to track the current state
RenderMode current_mode = NORMAL;

int x_offset;
int y_offset;
int top_left_img_x;
int top_left_img_y;
int bottom_right_img_x;
int bottom_right_img_y;

typedef struct
{
    int x[10];
    int y[10];
    int n;
    uint16_t color;

} Shape;
// end program variables

// begin program function prototypes
/* function prototypes */
void VGA_text(int, int, char *);
void VGA_text_clear();
void VGA_box(int, int, int, int, short);
void VGA_line(int, int, int, int, short);
void VGA_disc(int, int, int, short);
int VGA_read_pixel(int, int);
int video_in_read_pixel(int, int);
void draw_delay(void);
// start function prototypes we made
float VGA_polygon(Shape *polygon, bool draw, float size_weight, float alpha);
int avalon_setup();
void VGA_setup();
Shape random_polygon(int N, int bounding_box);
uint16_t average_pixel(Shape *polygon);
uint16_t center_pixel_color(Shape *polygon);
uint16_t get_pixel_color(int x, int y);
uint16_t global_average_pixel();
void display_image(uint16_t *image);
void hill_climb(float size_weight, float bounding_box, int mutate_vertex_delta, int mutate_shift_delta, float alpha);
float sse_objective(int row, int col, uint16_t pixel_color);
Shape mutate(Shape *polygon, int mutate_vertex_delta, int mutate_shift_delta);
Shape mutate_vertex(Shape *polygon, int mutate_vertex_delta);
Shape mutate_shift(Shape *polygon, int mutate_shift_delta);
void blur_display_3x3(int passes);
void scaled_image();
float approx_sqrt(float x);
float sse_extract_verilog(Shape *polygon, float size_weight);
void stream_image_to_fpga();
void reset();
void init_artwork();
void cycle_artwork();
uint8_t rgb565_to_rgb332(uint16_t pixel);
uint16_t rgb332_to_rgb565(uint8_t pixel);

#define GET_R_565to332_255(pixel) (((rgb565_to_rgb332((uint16_t)(pixel)) >> 5) & 0x7) * 36)
#define GET_G_565to332_255(pixel) (((rgb565_to_rgb332((uint16_t)(pixel)) >> 2) & 0x7) * 36)
#define GET_B_565to332_255(pixel) ((rgb565_to_rgb332((uint16_t)(pixel)) & 0x3) * 85)
// end program function prototypes


// measure time
struct timeval t1, t2;
float elapsedTime;
struct timespec delay_time;
static uint16_t image[ORIG_IMG_WIDTH * ORIG_IMG_HEIGHT];

/////////////////////////////////////////////////////////////
// read the keyboard
/////////////////////////////////////////////////////////////
void *read_keyboard()
{
    printf("Available Commands:\n");
    printf("p: num_polygons \nv: num_vertices \ni: num_iterations \na: end_alpha: \nm: mode: \nh: help (display this menu) \ns: save image \nf = load file \n");
    while (1)
    {
        // get user command through serial interface
        printf("Enter command: ");
        scanf("%s", user_input_buffer);

        // num_rows command
        if (user_input_buffer[0] == 'p')
        {
            printf("num_polygons command received\n");
            printf("Enter value for num_polygons: ");
            scanf("%s", user_input_buffer);
            // bounds check
            if (atof(user_input_buffer) >= 4.0f && atof(user_input_buffer) <= 100000.0f)
            {
                NUM_POLYGONS = atof(user_input_buffer);
                // print confirmtion to serial
                printf("New num_rows: %d\n", NUM_POLYGONS);
                reset();
            }
        }
        else if (user_input_buffer[0] == 'v')
        {
            printf("num_vertices command received\n");
            printf("Enter value for num_vertices: ");
            scanf("%s", user_input_buffer);
            // bounds check
            if (atof(user_input_buffer) >= 2.0f && atof(user_input_buffer) <= 10.0f)
            {
                NUM_VERTICES = atof(user_input_buffer);
                // print confirmtion to serial
                printf("New num_vertices: %d\n", NUM_VERTICES);
                reset();
            }
        }

        else if (user_input_buffer[0] == 'i')
        {
            printf("num_iterations command received\n");
            printf("Enter value for num_iterations: ");
            scanf("%s", user_input_buffer);
            // bounds check
            if (atof(user_input_buffer) >= 1.0f && atof(user_input_buffer) <= 1000.0f)
            {
                NUM_ITERATIONS = atof(user_input_buffer);
                // print confirmtion to serial
                printf("New num_vertices: %d\n", NUM_ITERATIONS);
                reset();
            }
        }

        else if (user_input_buffer[0] == 'a')
        {
            printf("end_alpha command received\n");
            printf("Enter value end_alpha: ");
            scanf("%a", user_input_buffer);
            // bounds check
            if (atof(user_input_buffer) >= 0.0 && atof(user_input_buffer) <= 1.0)
            {
                end_alpha = atof(user_input_buffer);
                // print confirmtion to serial
                printf("New end_alppha: %d\n", end_alpha);
                reset();
            }
        }

        else if (user_input_buffer[0] == 'm')
        {
            printf("mode command received\n");
            printf("Available Modes:\n");
            printf("  0 - NORMAL\n");
            printf("  1 - RED_SHIFT\n");
            printf("  2 - GREEN_SHIFT\n");
            printf("  3 - BLUE_SHIFT\n");
            printf("  4 - HALLUCINATE\n");
            printf("  5 - PAINT\n");
            printf("Enter value (0-5) for mode: ");
            scanf("%63s", user_input_buffer);
            // bounds check
            if (atoi(user_input_buffer) >= 0 && atoi(user_input_buffer) <= 5)
            {
                current_mode = (RenderMode)atoi(user_input_buffer);
                // print confirmtion to serial
                printf("New mode: %d\n", current_mode);
                reset();
            }
        }
        else if (user_input_buffer[0] == 'h')
        {
            printf("Available Commands:\n");
            printf("p: num_polygons \nv: num_vertices \ni: num_iterations \na: end_alpha: \nm: mode: \nh: help (display this menu) \ns: save image \nf = load file \n");
        }
        else if (user_input_buffer[0] == 's')
        {
            printf("Enter filename (e.g., painting.bmp): ");
            scanf("%63s", user_input_buffer);
            save_vga_to_bmp(user_input_buffer);
        }
        else if (user_input_buffer[0] == 'f')
        {
            printf("File load command received\n");
            printf("Enter exact filename (e.g., newer_picture.txt): ");
            scanf("%63s", user_input_buffer);
            strncpy(target_image_file, user_input_buffer, 63);
            target_image_file[63] = '\0';
            printf("Attempting to load new masterpiece (best effort): %s\n", target_image_file);
            reset();
        }
        else
        {
            printf("Unknown command\n");
        }
    }
}


/////////////////////////////////////////////////////////////
// create artwork
/////////////////////////////////////////////////////////////

void init_artwork()
{
    // good_count = 0;
    // total_sse = 0;
    int i;
    i = read_txt_to_1d_array(target_image_file, image, ORIG_IMG_WIDTH * ORIG_IMG_HEIGHT);
    scaled_image();

    // start the timer
    gettimeofday(&t1, NULL);

    // start the timer
    gettimeofday(&t1, NULL);

    uint16_t avg_img_color = global_average_pixel();
    VGA_box(top_left_img_x, top_left_img_y, bottom_right_img_x, bottom_right_img_y, avg_img_color);

    start_weight = 0.8; // 0.8
    end_weight = 0.01;
    start_bounding_box = 10; // 5 before, 100 too much
    end_bounding_box = 10;   // 5
    start_mutate_delta = 50;
    end_mutate_delta = 2;
    start_mutate_shift = 100;
    end_mutate_shift = 2;
    start_alpha = 1.0;
    end_alpha = 0.3;
}

void cycle_artwork()
{
    int j;
    float current_weight;
    float current_bounding_box;
    float current_mutate_delta;
    float current_mutate_shift;
    float current_alpha;

    while (1)
    {
        for (j = 0; j < NUM_POLYGONS; j++)
        {
            float progress = (float)j / NUM_POLYGONS;

            current_weight = start_weight - (start_weight - end_weight) * approx_sqrt(progress);
            current_bounding_box = start_bounding_box - (start_bounding_box - end_bounding_box) * approx_sqrt(progress);
            current_mutate_delta = start_mutate_delta - (start_mutate_delta - end_mutate_delta) * approx_sqrt(progress);
            current_mutate_shift = start_mutate_shift - (start_mutate_shift - end_mutate_shift) * approx_sqrt(progress);
            current_alpha = start_alpha - (start_alpha - end_alpha) * approx_sqrt(progress);

            hill_climb(current_weight, current_bounding_box, current_mutate_delta, current_mutate_shift, current_alpha);

            if (reset_requested)
            {
                VGA_setup();
                init_artwork();
                j = 0;
                reset_requested = false;
            }
        }

        // end timer
        gettimeofday(&t2, NULL);
        elapsedTime = (t2.tv_sec - t1.tv_sec);
        elapsedTime += (t2.tv_usec - t1.tv_usec) / 1000000.0;
        sprintf(time_string, "T=%.3f s      ", elapsedTime);
        // VGA_text (10, 3, num_string);
        VGA_text(64, 59, time_string);

        while (!reset_requested)
        {
            usleep(5);
        }
        VGA_setup();
        init_artwork();
        j = 0;
        reset_requested = false;
    }
}

void *create_artwork()
{
    init_artwork();
    stream_image_to_fpga();
    cycle_artwork();
}

/////////////////////////////////////////////////////////////
// MAIN
/////////////////////////////////////////////////////////////

int main(void)
{
    srand(42);
    // global_counter = 0;
    avalon_setup();

    poly_x_1 = (signed int *)(h2p_lw_virtual_base + POLY_X_1_OFFSET);
    poly_x_2 = (signed int *)(h2p_lw_virtual_base + POLY_X_2_OFFSET);
    poly_x_3 = (signed int *)(h2p_lw_virtual_base + POLY_X_3_OFFSET);
    poly_x_4 = (signed int *)(h2p_lw_virtual_base + POLY_X_4_OFFSET);
    poly_y_1 = (signed int *)(h2p_lw_virtual_base + POLY_Y_1_OFFSET);
    poly_y_2 = (signed int *)(h2p_lw_virtual_base + POLY_Y_2_OFFSET);
    poly_y_3 = (signed int *)(h2p_lw_virtual_base + POLY_Y_3_OFFSET);
    poly_y_4 = (signed int *)(h2p_lw_virtual_base + POLY_Y_4_OFFSET);
    poly_clr = (unsigned int *)(h2p_lw_virtual_base + POLY_COLOR_OFFSET);
    poly_size_weight = (float *)(h2p_lw_virtual_base + SIZE_WEIGHT_OFFSET);
    in_valid = (unsigned int *)(h2p_lw_virtual_base + IN_VALID_OFFSET);
    out_valid = (unsigned int *)(h2p_lw_virtual_base + OUT_VALID_OFFSET);
    out_ack = (unsigned int *)(h2p_lw_virtual_base + OUT_ACK_OFFSET);
    poly_sse = (float *)(h2p_lw_virtual_base + POLY_SSE_OFFSET);
    image_stream_rgb = (signed int *)(h2p_lw_virtual_base + IMAGE_STREAM_RGB_OFFSET);
    image_stream_x = (unsigned int *)(h2p_lw_virtual_base + IMAGE_STREAM_X_OFFSET);
    image_stream_y = (unsigned int *)(h2p_lw_virtual_base + IMAGE_STREAM_Y_OFFSET);
    write_en = (unsigned int *)(h2p_lw_virtual_base + WRITE_EN_OFFSET);

    *poly_x_1 = 0;
    *poly_x_2 = 0;
    *poly_x_3 = 0;
    *poly_x_4 = 0;
    *poly_y_1 = 0;
    *poly_y_2 = 0;
    *poly_y_3 = 0;
    *poly_y_4 = 0;
    *poly_clr = 0;
    *poly_size_weight = 0;
    *in_valid = 0;
    // *out_valid = 0;
    *out_ack = 0;
    // *poly_sse = 0;
    *image_stream_rgb = 0;
    *image_stream_x = 0;
    *image_stream_y = 0;
    *write_en = 0;

    VGA_setup();

    // pthread setup
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);

    // put just one processsor into the list
    CPU_SET(0, &cpuset);

    // Schedule threads
    // the thread identifiers
    pthread_t thread_keyboard, thread_artwork; //, thread_reset;

    // For portability, explicitly create threads in a joinable state
    // thread attribute used here to allow JOIN
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);
    pthread_create(&thread_keyboard, NULL, read_keyboard, NULL);
    pthread_create(&thread_artwork, NULL, create_artwork, NULL);

    // In this case the thread never exit
    pthread_join(thread_keyboard, NULL);
    pthread_join(thread_artwork, NULL);

    return 0;
} // end main

void VGA_setup()
{
    // set time delay
    delay_time.tv_nsec = 10;
    delay_time.tv_sec = 0;

    char text_top_row[40] = "Poly-paint\0";
    char text_bottom_row[40] = "mff56,mpm297,yb265\0";
    char num_string[20];

    // clear the text
    VGA_text_clear();
    // clear the screen
    VGA_box(0, 0, 639, 479, 0x00);
    VGA_text(1, 58, text_top_row);
    VGA_text(1, 59, text_bottom_row);

    x_offset = (ORIG_IMG_WIDTH - MAX_WIDTH) / 2;
    y_offset = (ORIG_IMG_HEIGHT - MAX_HEIGHT) / 2;
    top_left_img_x = 0 - x_offset;
    top_left_img_y = y_offset;
    bottom_right_img_x = SCREEN_IMG_WIDTH - 1 - x_offset;
    bottom_right_img_y = SCREEN_IMG_HEIGHT - 1 + y_offset;
}

void stream_image_to_fpga()
{
    int x, y;
    volatile int k; // Required to stop GCC from optimizing away the delay!

    // printf("Streaming %s to center of FPGA...\n", target_image_file);
    // 2. Stream the centered image directly on top!
    int screen_row;
    for (screen_row = 0; screen_row < SCREEN_IMG_HEIGHT; screen_row++)
    {
        int screen_col;
        for (screen_col = 0; screen_col < SCREEN_IMG_WIDTH; screen_col++)
        {

            uint16_t pixel16 = xform_image_raw[screen_row * SCREEN_IMG_WIDTH + screen_col];
            uint8_t pixel8 = rgb565_to_rgb332(pixel16);

            // Shift the image to the exact center to align with the VGA
            int dest_x = screen_col; // - x_offset;
            int dest_y = screen_row; // + y_offset;


            *image_stream_rgb = (unsigned int)pixel8;
            *image_stream_x = (unsigned int)dest_x;
            *image_stream_y = (unsigned int)dest_y;
            // MEMORY BARRIER: read-back forces Avalon bus to complete all pending writes
            // before we assert write_en. Without this, write_en can arrive at the FPGA
            // before rgb/x/y have settled in their PIO registers.
            volatile unsigned int barrier = *image_stream_y;
            (void)barrier;
            *write_en = 0;
            *write_en = 1;

        }
    }
    // printf("Image Streaming Complete! Commencing Art.\n");
}

int avalon_setup()
{
    if ((fd = open("/dev/mem", (O_RDWR | O_SYNC))) == -1)
    {
        printf("ERROR: could not open \"/dev/mem\"...\n");
        return (1);
    }

    // get virtual addr that maps to physical
    h2p_lw_virtual_base = mmap(NULL, HW_REGS_SPAN, (PROT_READ | PROT_WRITE), MAP_SHARED, fd, HW_REGS_BASE);
    if (h2p_lw_virtual_base == MAP_FAILED)
    {
        printf("ERROR: mmap1() failed...\n");
        close(fd);
        return (1);
    }

    // === get VGA char addr =====================
    // get virtual addr that maps to physical
    vga_char_virtual_base = mmap(NULL, FPGA_CHAR_SPAN, (PROT_READ | PROT_WRITE), MAP_SHARED, fd, FPGA_CHAR_BASE);
    if (vga_char_virtual_base == MAP_FAILED)
    {
        printf("ERROR: mmap2() failed...\n");
        close(fd);
        return (1);
    }

    // Get the address that maps to the FPGA LED control
    vga_char_ptr = (unsigned int *)(vga_char_virtual_base);

    // === get VGA pixel addr ====================
    // get virtual addr that maps to physical
    vga_pixel_virtual_base = mmap(NULL, SDRAM_SPAN, (PROT_READ | PROT_WRITE), MAP_SHARED, fd, SDRAM_BASE);
    if (vga_pixel_virtual_base == MAP_FAILED)
    {
        printf("ERROR: mmap3() failed...\n");
        close(fd);
        return (1);
    

    // Get the address that maps to the FPGA pixel buffer
    vga_pixel_ptr = (unsigned int *)(vga_pixel_virtual_base);
}

void reset()
{
    // VGA_setup();
    // init_artwork();
    reset_requested = true;
}

// TODO: can be x and y after image transform
uint16_t get_pixel_color(int x, int y)
{
    // if (x < 0 || x > 639 ||
    //  y < 0 || y > 479)
    // {
    //  return 0x00;
    // }

    if (x < 160 || x > 480)
    {
        return 0x00;
    }
    return xform_image_raw[y * 320 + x - 160]; // or
}

int VGA_read_pixel(int x, int y)
{
    volatile uint16_t *pixel_ptr;

    pixel_ptr = (volatile uint16_t *)((char *)vga_pixel_ptr + (((y * 640) + x) << 1));

    return (int)(*pixel_ptr);
}

void save_vga_to_bmp(const char *filename)
{
    FILE *f;
    int w = 640;
    int h = 480;

    // 54 byte header + (640 * 480 pixels * 3 bytes per pixel)
    int filesize = 54 + 3 * w * h;

    // Hardcode the standard BMP file headers
    unsigned char bmpfileheader[14] = {'B', 'M', 0, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0};
    unsigned char bmpinfoheader[40] = {40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 24, 0};

    // Splice in the filesize
    bmpfileheader[2] = (unsigned char)(filesize);
    bmpfileheader[3] = (unsigned char)(filesize >> 8);
    bmpfileheader[4] = (unsigned char)(filesize >> 16);
    bmpfileheader[5] = (unsigned char)(filesize >> 24);

    // Splice in the width and height
    bmpinfoheader[4] = (unsigned char)(w);
    bmpinfoheader[5] = (unsigned char)(w >> 8);
    bmpinfoheader[6] = (unsigned char)(w >> 16);
    bmpinfoheader[7] = (unsigned char)(w >> 24);
    bmpinfoheader[8] = (unsigned char)(h);
    bmpinfoheader[9] = (unsigned char)(h >> 8);
    bmpinfoheader[10] = (unsigned char)(h >> 16);
    bmpinfoheader[11] = (unsigned char)(h >> 24);

    f = fopen(filename, "wb"); // 'wb' is critical for binary writing in Linux
    if (!f)
    {
        printf("Error creating BMP file!\n");
        return;
    }

    fwrite(bmpfileheader, 1, 14, f);
    fwrite(bmpinfoheader, 1, 40, f);

    // CRITICAL: BMP files are drawn upside down (bottom to top)!
    int i, j;
    for (i = h - 1; i >= 0; i--)
    {
        for (j = 0; j < w; j++)
        {
            int pixel = VGA_read_pixel(j, i);

            // Unpack 3-3-2 color and scale up to 0-255
            int r = ((pixel >> 11) & 0x1F) * 255 / 31;
            int g = ((pixel >> 5) & 0x3F) * 255 / 63;
            int b = (pixel & 0x1F) * 255 / 31;

            // BMP format specifically requires BGR order, not RGB!
            unsigned char color[3] = {b, g, r};
            fwrite(color, 1, 3, f);
        }
        // Note: BMP requires rows to be padded to multiples of 4 bytes.
        // 640 * 3 = 1920. 1920 % 4 is 0, so we get to skip padding entirely!
    }

    fclose(f);
    printf("Masterpiece saved to %s\n", filename);
}

// BEGIN AI PRODUCED CODE ------>
int read_txt_to_1d_array(const char *filename, uint16_t *array, int size)
{
    FILE *fp = fopen(filename, "r");
    if (fp == NULL)
    {
        return 0;
    }

    int i;
    for (i = 0; i < size; i++)
    {
        int temp;
        if (fscanf(fp, "%d", &temp) != 1)
        {
            fclose(fp);
            return 0;
        }
        array[i] = (uint16_t)temp;
    }

    fclose(fp);
    return 1;
}

void display_image(uint16_t *image)
{
    int screen_row;
    int screen_col;

    int x_offset = (ORIG_IMG_WIDTH - MAX_WIDTH) / 2;
    int y_offset = (ORIG_IMG_HEIGHT - MAX_HEIGHT) / 2;

    for (screen_row = 0; screen_row < SCREEN_IMG_HEIGHT; screen_row++)
    {
        for (screen_col = 0; screen_col < SCREEN_IMG_WIDTH; screen_col++)
        {
            int img_row = (screen_row * ORIG_IMG_HEIGHT) / SCREEN_IMG_HEIGHT;
            int img_col = (screen_col * ORIG_IMG_WIDTH) / SCREEN_IMG_WIDTH;

            uint16_t pixel = image[img_row * ORIG_IMG_WIDTH + img_col];
            VGA_PIXEL(screen_col - x_offset, screen_row + y_offset, pixel);
        }
    }
}
// <------ END AI PRODUCED CODE

void scaled_image()
{
    int screen_row = 0;
    for (screen_row = 0; screen_row < SCREEN_IMG_HEIGHT; screen_row++)
    {
        int screen_col = 0;
        for (screen_col = 0; screen_col < SCREEN_IMG_WIDTH; screen_col++)
        {
            int img_row = (screen_row * ORIG_IMG_HEIGHT) / SCREEN_IMG_HEIGHT;
            int img_col = (screen_col * ORIG_IMG_WIDTH) / SCREEN_IMG_WIDTH;

            uint16_t pixel = image[img_row * ORIG_IMG_WIDTH + img_col];

            int dest_x = screen_col - x_offset;
            int dest_y = screen_row + y_offset;

            if (dest_x >= 0 && dest_x < MAX_WIDTH && dest_y >= 0 && dest_y < MAX_HEIGHT)
            {
                xform_image[(dest_y * MAX_WIDTH) + dest_x] = pixel;
            }
            xform_image_raw[(screen_row * SCREEN_IMG_WIDTH) + screen_col] = pixel;
        }
    }
}

// BEGIN AI ADJUSTED CODE ------>
float VGA_polygon(Shape *polygon, bool draw, float size_weight, float alpha)
{
    // 1. Declare all variables at the top of the function block
    int i, j, row;
    int min_y, max_y;
    int hits[16];
    int num_hits;
    int yi, yj;
    int x1, x2;
    unsigned char *row_ptr;

    float sse_polygon = 0;
    float pixel_count = 0;

    // 2. Initialize variables after all declarations are done
    min_y = polygon->y[0];
    max_y = polygon->y[0];

    // Make complexity scale with one geometric dimension
    // You only have to check the N vertices
    for (i = 1; i < polygon->n; i++)
    {
        if (polygon->y[i] < min_y)
            min_y = polygon->y[i];
        if (polygon->y[i] > max_y)
            max_y = polygon->y[i];
    }

    // in case we go beyond the bounds of the screen
    if (min_y < 0)
        min_y = 0;
    if (max_y > 479)
        max_y = 479;

    // loop over each row within y bounds
    for (row = min_y; row <= max_y; row++)
    {
        num_hits = 0;

        // Compact way to loop through every polygon edge
        for (i = 0, j = polygon->n - 1; i < polygon->n; j = i++)
        {
            yi = polygon->y[i];
            yj = polygon->y[j];

            // if y coordinates of edge are on either side of row
            if ((yi > row) != (yj > row))
            {
                // we have one intersection, save the x coordinate of the intersection
                hits[num_hits++] = polygon->x[i] + (row - yi) * (polygon->x[j] - polygon->x[i]) / (yj - yi);
            }
        }

        // sort the x-coordinates of intersection for current row
        for (i = 0; i < num_hits - 1; i++)
        {
            for (j = i + 1; j < num_hits; j++)
            {
                if (hits[j] < hits[i])
                {
                    SWAP(hits[i], hits[j]);
                }
            }
        }

        // fill in pixels
        row_ptr = (unsigned char *)vga_pixel_ptr + row * 640;

        // loop through pairs of intersections and fill in
        for (i = 0; i < num_hits - 1; i += 2)
        {
            x1 = hits[i];
            x2 = hits[i + 1];

            if (x1 < 0)
                x1 = 0;
            if (x2 > 639)
                x2 = 639;

            if (draw)
            {
                // printf("Drawing row %d from x=%d to x=%d\n", row, x1, x2);
                int col;
                for (col = x1; col <= x2; col++)
                {
                    bool shift = (current_mode == RED_SHIFT) || (current_mode == GREEN_SHIFT) || (current_mode == BLUE_SHIFT);
                    if (current_mode == HALLUCINATE)
                    {
                        VGA_PIXEL(col, row, (alpha)*polygon->color + (1 - alpha) * VGA_read_pixel(col, row)); // use this for super cool typo -> psychadelic blending effects!
                    }
                    else
                    {
                        // must scale all values to 0-255
                        float r = GET_R_255(polygon->color);
                        float g = GET_G_255(polygon->color);
                        float b = GET_B_255(polygon->color);

                        float blue_255 = alpha * b + (1 - alpha) * GET_B_255(VGA_read_pixel(col, row));
                        float red_255 = alpha * r + (1 - alpha) * GET_R_255(VGA_read_pixel(col, row));
                        float green_255 = alpha * g + (1 - alpha) * GET_G_255(VGA_read_pixel(col, row));

                        int blue_temp;
                        int red_temp;
                        int green_temp;

                        if (current_mode == RED_SHIFT)
                        {
                            blue_temp = blue_255 / 4;
                            red_temp = red_255;
                            green_temp = green_255 / 4;
                        }
                        else if (current_mode == GREEN_SHIFT)
                        {
                            blue_temp = blue_255 / 4;
                            red_temp = red_255 / 4;
                            green_temp = green_255;
                        }
                        else if (current_mode == BLUE_SHIFT)
                        {
                            blue_temp = blue_255;
                            red_temp = red_255 / 4;
                            green_temp = green_255 / 4;
                        }
                        else
                        {
                            blue_temp = blue_255;
                            red_temp = red_255;
                            green_temp = green_255;
                        }

                        uint16_t blended_color = ((red_temp >> 3) << 11) | ((green_temp >> 2) << 5) | (blue_temp >> 3);

                        VGA_PIXEL(col, row, blended_color);
                    }
                }
            }
            else
            {
                int col;
                for (col = x1; col <= x2; col += N_PIXEL_SSE)
                {
                    sse_polygon += sse_objective(row, col, polygon->color);
                    pixel_count += 1;
                }
            }
        }
    }

    if (pixel_count == 0)
    {
        return 999999999; // bad score so it gets rejected
    }
    return sse_polygon - 16384 * (size_weight)*pixel_count;
}
// <------ END AI ADJUSTED CODE

float sse_objective(int row, int col, uint16_t pixel_color)
{
    float error = 0; // give as much precision as possible to avoid overflow

    uint16_t pixel_one = pixel_color;
    uint16_t pixel_two = get_pixel_color(col, row); // VGA_read_pixel(col, row);
    // printf("pixel_one: %d\n", rgb565_to_rgb332(pixel_one));
    // printf("pixel_two: %d\n\n", rgb565_to_rgb332(pixel_two));
    // must scale all values to 0-255
    float r = GET_R_565to332_255(pixel_one) - GET_R_565to332_255(pixel_two);
    float g = GET_G_565to332_255(pixel_one) - GET_G_565to332_255(pixel_two);
    float b = GET_B_565to332_255(pixel_one) - GET_B_565to332_255(pixel_two);

    error += (r * r + g * g + b * b);

    return error;
}

float approx_sqrt(float x)
{
    if (x <= 0.0)
        return 0.0;
    if (x >= 1.0)
        return 1.0;

    if (x < 0.0625)
        return 4.0 * x; // through (0,0) and (0.0625,0.25)
    else if (x < 0.25)
        return 0.25 + (x - 0.0625) * (4.0 / 3.0); // to (0.25,0.5)
    else if (x < 0.5625)
        return 0.5 + (x - 0.25) * (4.0 / 5.0); // to (0.5625,0.75)
    else
        return 0.75 + (x - 0.5625) * (4.0 / 7.0); // to (1,1)
}

Shape random_polygon(int N, int bounding_box)
{
    Shape polygon;
    uint16_t color;

    // Generate N random points across 10x10 subresolution
    int i;
    for (i = 0; i < N; i++)
    {
        polygon.x[i] = rand() % bounding_box;
        polygon.y[i] = rand() % bounding_box;
    }

    // move to random point on the screen
    int j;
    // int x_offset = rand() % 640 - X_OFFSET_IMG;
    int x_offset = (rand() % SCREEN_IMG_WIDTH) + IMG_LEFT - (bounding_box / 2);
    int y_offset = (rand() % 480) - (bounding_box / 2);
    for (j = 0; j < N; j++)
    {
        polygon.x[j] = polygon.x[j] + x_offset;
        polygon.y[j] = polygon.y[j] + y_offset;
    }

    polygon.n = N;

    // color = average_pixel(&polygon); 36
    color = center_pixel_color(&polygon);

    polygon.color = color;
    // Call the function with N=4
    return polygon;
}

void print_float_binary(float f)
{
    uint32_t bits;
    // Copy the bits from float to an unsigned 32-bit integer
    memcpy(&bits, &f, sizeof(bits));
    int i;
    for (i = 31; i >= 0; i--)
    {
        // Shift bit to the right and use bitwise AND to get its value
        printf("%d", (bits >> i) & 1);

        // Optional: add spaces for readability (Sign, Exponent, Mantissa)
        if (i == 31 || i == 23)
            printf(" ");
    }
    printf("\n");
}

void hill_climb(float size_weight, float bounding_box, int mutate_vertex_delta, int mutate_shift_delta, float alpha)
{
    float current_sse = 0;
    Shape current_polygon = random_polygon(NUM_VERTICES, bounding_box);

    // float c_version_sse = VGA_polygon(&current_polygon, false, size_weight, alpha);

    sse_extract_verilog(&current_polygon, size_weight); // write to FPGA

    while (!*out_valid)
    {
        // printf("waiting, spinning \n");

    } // wait for FPGA to be done


    *out_ack = 1;
    *out_ack = 0;

    current_sse = *poly_sse; // read from FPGA
	// current_sse = c_version_sse; // temp for testing 654
    
    Shape temp_polygon;


    int i = 0;
    for (i = 0; i < NUM_ITERATIONS; i++)
    {
        temp_polygon = mutate(&current_polygon, mutate_vertex_delta, mutate_shift_delta);
        float temp_sse;
        // float c_sse = VGA_polygon(&temp_polygon, false, size_weight, alpha);

        // FOR VERILOG
        sse_extract_verilog(&temp_polygon, size_weight); // write to FPGA
        while (!*out_valid)
        {
            // printf("waiting, spinning \n");

        } // wait for FPGA to be done

        temp_sse = *poly_sse; // read from FPGA

        *out_ack = 1;
        *out_ack = 0;

        if (temp_sse < current_sse) // temp_sse
        {
            current_sse = temp_sse;
            current_polygon = temp_polygon;
        }
    }

    VGA_polygon(&current_polygon, true, size_weight, alpha);
    total_sse += current_sse;
}

float sse_extract_verilog(Shape *polygon, float size_weight_in)
{
    *poly_x_1 = polygon->x[0];
    *poly_y_1 = polygon->y[0];
    *poly_x_2 = polygon->x[1];
    *poly_y_2 = polygon->y[1];
    *poly_x_3 = polygon->x[2];
    *poly_y_3 = polygon->y[2];
    *poly_x_4 = polygon->x[0];
    *poly_y_4 = polygon->y[0];

    *poly_size_weight = size_weight_in;

    *poly_clr = (unsigned int)rgb565_to_rgb332(polygon->color);

    *in_valid = 1;
    usleep(5);
    *in_valid = 0;

    return 0.0f;
}

Shape mutate(Shape *polygon, int mutate_vertex_delta, int mutate_shift_delta)
{
    return mutate_vertex(polygon, mutate_vertex_delta);
}


Shape mutate_vertex(Shape *polygon, int mutate_vertex_delta)
{
    int vertex_to_mutate = rand() % polygon->n;
    int new_x;
    int new_y;

    if (current_mode == PAINT)
    {
        new_x = polygon->x[vertex_to_mutate] + (rand() % (mutate_vertex_delta));
        new_y = polygon->y[vertex_to_mutate] + (rand() % (mutate_vertex_delta));
    }
    else
    {
        new_x = polygon->x[vertex_to_mutate] + (rand() % (2 * mutate_vertex_delta + 1)) - mutate_vertex_delta;
        new_y = polygon->y[vertex_to_mutate] + (rand() % (2 * mutate_vertex_delta + 1)) - mutate_vertex_delta;
    }

    if (new_x < top_left_img_x)
        new_x = top_left_img_x;
    if (new_x > bottom_right_img_x)
        new_x = bottom_right_img_x;
    if (new_y < top_left_img_y)
        new_y = top_left_img_y;
    if (new_y > bottom_right_img_y)
        new_y = bottom_right_img_y;

    Shape new_polygon = *polygon;
    new_polygon.x[vertex_to_mutate] = new_x;
    new_polygon.y[vertex_to_mutate] = new_y;

    return new_polygon;
}

Shape mutate_shift(Shape *polygon, int mutate_shift_delta)
{
    // make x and y different and positive and negative
    Shape new_polygon = *polygon;
    int x_value_to_shift = 2 * (rand() % (int)mutate_shift_delta) - (int)mutate_shift_delta;
    int y_value_to_shift = 2 * (rand() % (int)mutate_shift_delta) - (int)mutate_shift_delta;

    int i = 0;
    for (i = 0; i < polygon->n; i++)
    {
        new_polygon.x[i] = polygon->x[i] + x_value_to_shift;
        new_polygon.y[i] = polygon->y[i] + y_value_to_shift;

        bool x_out = (new_polygon.x[i] < top_left_img_x) || (new_polygon.x[i] > bottom_right_img_x);
        bool y_out = (new_polygon.y[i] < top_left_img_y) || (new_polygon.y[i] > bottom_right_img_y);

        if (x_out || y_out)
        {
            return *polygon;
        }
    }

    return new_polygon;
    // return *polygon; // temp
}

static int get_row_hits(Shape *polygon, int row, int hits[])
{
    int i;
    int j;
    int yi;
    int yj;
    int num_hits = 0;

    for (i = 0, j = polygon->n - 1; i < polygon->n; j = i++)
    {
        yi = polygon->y[i];
        yj = polygon->y[j];

        // if y coordinates of edge are on either side of row
        if ((yi > row) != (yj > row))
        {
            // save x coordinate of intersection
            hits[num_hits++] =
                polygon->x[i] + (row - yi) * (polygon->x[j] - polygon->x[i]) / (yj - yi);
        }
    }

    // sort x-coordinates
    for (i = 0; i < num_hits - 1; i++)
    {
        for (j = i + 1; j < num_hits; j++)
        {
            if (hits[j] < hits[i])
            {
                SWAP(hits[i], hits[j]);
            }
        }
    }

    return num_hits;
}

uint16_t average_pixel(Shape *polygon)
{
    int sum_red = 0;
    int sum_blue = 0;
    int sum_green = 0;
    int count = 0;

    int i, row;
    int min_y, max_y;
    int hits[16];
    int num_hits;
    int x1, x2;

    min_y = polygon->y[0];
    max_y = polygon->y[0];

    for (i = 1; i < polygon->n; i++)
    {
        if (polygon->y[i] < min_y)
            min_y = polygon->y[i];
        if (polygon->y[i] > max_y)
            max_y = polygon->y[i];
    }

    if (min_y < 0)
        min_y = 0;
    if (max_y > 479)
        max_y = 479;

    for (row = min_y; row <= max_y; row++)
    {
        int col;

        num_hits = get_row_hits(polygon, row, hits);

        for (i = 0; i < num_hits - 1; i += 2)
        {
            x1 = hits[i];
            x2 = hits[i + 1];

            if (x1 < 0)
                x1 = 0;
            if (x2 > 639)
                x2 = 639;

            for (col = x1; col <= x2; col++)
            {
                sum_green += EXTRACT_GREEN_16(get_pixel_color(col, row));
                sum_blue += EXTRACT_BLUE_16(get_pixel_color(col, row));
                sum_red += EXTRACT_RED_16(get_pixel_color(col, row));
                count++;
            }
        }
    }

    if (count == 0)
    {
        return 0x00; // black
    }

    int avg_green = (sum_green + (count / 2)) / count;
    int avg_blue = (sum_blue + (count / 2)) / count;
    int avg_red = (sum_red + (count / 2)) / count;

    if (avg_red > 31)
        avg_red = 31;
    if (avg_green > 63)
        avg_green = 63;
    if (avg_blue > 31)
        avg_blue = 31;
    return (avg_red << 11) | (avg_green << 5) | avg_blue;
}

uint16_t center_pixel_color(Shape *polygon)
{
    int center_x = 0;
    int center_y = 0;
    int i;
    for (i = 0; i < polygon->n; i++)
    {
        center_x += polygon->x[i];
        center_y += polygon->y[i];
    }
    center_x /= polygon->n;
    center_y /= polygon->n;

    return get_pixel_color(center_x, center_y);
}

uint16_t global_average_pixel()
{
    // Using global variable image
    int sum_red = 0;
    int sum_blue = 0;
    int sum_green = 0;
    int count = 0;

    int length = ORIG_IMG_HEIGHT * ORIG_IMG_WIDTH; // parameterized off #bytes per entry

    int i;
    // iterate through all coordinates
    for (i = 0; i < length; i++)
    {
        int pixel_val = image[i];
        int blue_extract = EXTRACT_BLUE_16(pixel_val);
        int red_extract = EXTRACT_RED_16(pixel_val);
        int green_extract = EXTRACT_GREEN_16(pixel_val);
        sum_red += red_extract;
        sum_green += green_extract;
        sum_blue += blue_extract;
        count++;
    }
    if (count == 0)
    {
        return 0x00; // black
    }

    int avg_green = sum_green / count;
    int avg_blue = sum_blue / count;
    int avg_red = sum_red / count;

    uint16_t color = (avg_red << 11) | (avg_green << 5) | avg_blue;

    return color;
}

// BEGIN VGA IMPORTED FUNCTIONS

/****************************************************************************************
 * Subroutine to send a string of text to the VGA monitor
 ****************************************************************************************/
void VGA_text(int x, int y, char *text_ptr)
{
    volatile char *character_buffer = (char *)vga_char_ptr; // VGA character buffer
    int offset;
    /* assume that the text string fits on one line */
    offset = (y << 7) + x;
    while (*(text_ptr))
    {
        // write to the character buffer
        *(character_buffer + offset) = *(text_ptr);
        ++text_ptr;
        ++offset;
    }
}

/****************************************************************************************
 * Subroutine to clear text to the VGA monitor
 ****************************************************************************************/
void VGA_text_clear()
{
    volatile char *character_buffer = (char *)vga_char_ptr; // VGA character buffer
    int offset, x, y;
    for (x = 0; x < 79; x++)
    {
        for (y = 0; y < 60; y++)
        {
            /* assume that the text string fits on one line */
            offset = (y << 7) + x;
            // write to the character buffer
            *(character_buffer + offset) = ' ';
        }
    }
}

/****************************************************************************************
 * Draw a filled rectangle on the VGA monitor
 ****************************************************************************************/

void VGA_box(int x1, int y1, int x2, int y2, short pixel_color)
{
    char *pixel_ptr;
    int row, col;

    /* check and fix box coordinates to be valid */
    if (x1 > 639)
        x1 = 639;
    if (y1 > 479)
        y1 = 479;
    if (x2 > 639)
        x2 = 639;
    if (y2 > 479)
        y2 = 479;
    if (x1 < 0)
        x1 = 0;
    if (y1 < 0)
        y1 = 0;
    if (x2 < 0)
        x2 = 0;
    if (y2 < 0)
        y2 = 0;
    if (x1 > x2)
        SWAP(x1, x2);
    if (y1 > y2)
        SWAP(y1, y2);
    for (row = y1; row <= y2; row++)
        for (col = x1; col <= x2; ++col)
        {
            // 640x480
            // pixel_ptr = (char *)vga_pixel_ptr + (row<<10)    + col ;
            //  set pixel color
            //*(char *)pixel_ptr = pixel_color;
            VGA_PIXEL(col, row, pixel_color);
        }
}

/****************************************************************************************
 * Draw a outline rectangle on the VGA monitor
 ****************************************************************************************/
#define SWAP(X, Y)    \
    do                \
    {                 \
        int temp = X; \
        X = Y;        \
        Y = temp;     \
    } while (0)

void VGA_rect(int x1, int y1, int x2, int y2, short pixel_color)
{
    char *pixel_ptr;
    int row, col;

    /* check and fix box coordinates to be valid */
    if (x1 > 639)
        x1 = 639;
    if (y1 > 479)
        y1 = 479;
    if (x2 > 639)
        x2 = 639;
    if (y2 > 479)
        y2 = 479;
    if (x1 < 0)
        x1 = 0;
    if (y1 < 0)
        y1 = 0;
    if (x2 < 0)
        x2 = 0;
    if (y2 < 0)
        y2 = 0;
    if (x1 > x2)
        SWAP(x1, x2);
    if (y1 > y2)
        SWAP(y1, y2);
    // left edge
    col = x1;
    for (row = y1; row <= y2; row++)
    {
        // 640x480
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10)    + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
    }

    // right edge
    col = x2;
    for (row = y1; row <= y2; row++)
    {
        // 640x480
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10)    + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
    }

    // top edge
    row = y1;
    for (col = x1; col <= x2; ++col)
    {
        // 640x480
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10)    + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
    }

    // bottom edge
    row = y2;
    for (col = x1; col <= x2; ++col)
    {
        // 640x480
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10)    + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
    }
}

/****************************************************************************************
 * Draw a horixontal line on the VGA monitor
 ****************************************************************************************/
#define SWAP(X, Y)    \
    do                \
    {                 \
        int temp = X; \
        X = Y;        \
        Y = temp;     \
    } while (0)

void VGA_Hline(int x1, int y1, int x2, short pixel_color)
{
    char *pixel_ptr;
    int row, col;

    /* check and fix box coordinates to be valid */
    if (x1 > 639)
        x1 = 639;
    if (y1 > 479)
        y1 = 479;
    if (x2 > 639)
        x2 = 639;
    if (x1 < 0)
        x1 = 0;
    if (y1 < 0)
        y1 = 0;
    if (x2 < 0)
        x2 = 0;
    if (x1 > x2)
        SWAP(x1, x2);
    // line
    row = y1;
    for (col = x1; col <= x2; ++col)
    {
        // 640x480
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10)    + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
    }
}

/****************************************************************************************
 * Draw a vertical line on the VGA monitor
 ****************************************************************************************/
#define SWAP(X, Y)    \
    do                \
    {                 \
        int temp = X; \
        X = Y;        \
        Y = temp;     \
    } while (0)

void VGA_Vline(int x1, int y1, int y2, short pixel_color)
{
    char *pixel_ptr;
    int row, col;

    /* check and fix box coordinates to be valid */
    if (x1 > 639)
        x1 = 639;
    if (y1 > 479)
        y1 = 479;
    if (y2 > 479)
        y2 = 479;
    if (x1 < 0)
        x1 = 0;
    if (y1 < 0)
        y1 = 0;
    if (y2 < 0)
        y2 = 0;
    if (y1 > y2)
        SWAP(y1, y2);
    // line
    col = x1;
    for (row = y1; row <= y2; row++)
    {
        // 640x480
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10)    + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
    }
}

/****************************************************************************************
 * Draw a filled circle on the VGA monitor
 ****************************************************************************************/

void VGA_disc(int x, int y, int r, short pixel_color)
{
    char *pixel_ptr;
    int row, col, rsqr, xc, yc;

    rsqr = r * r;

    for (yc = -r; yc <= r; yc++)
        for (xc = -r; xc <= r; xc++)
        {
            col = xc;
            row = yc;
            // add the r to make the edge smoother
            if (col * col + row * row <= rsqr + r)
            {
                col += x; // add the center point
                row += y; // add the center point
                // check for valid 640x480
                if (col > 639)
                    col = 639;
                if (row > 479)
                    row = 479;
                if (col < 0)
                    col = 0;
                if (row < 0)
                    row = 0;
                // pixel_ptr = (char *)vga_pixel_ptr + (row<<10) + col ;
                //  set pixel color
                //*(char *)pixel_ptr = pixel_color;
                VGA_PIXEL(col, row, pixel_color);
            }
        }
}

/****************************************************************************************
 * Draw a  circle on the VGA monitor
 ****************************************************************************************/

void VGA_circle(int x, int y, int r, int pixel_color)
{
    char *pixel_ptr;
    int row, col, rsqr, xc, yc;
    int col1, row1;
    rsqr = r * r;

    for (yc = -r; yc <= r; yc++)
    {
        // row = yc;
        col1 = (int)sqrt((float)(rsqr + r - yc * yc));
        // right edge
        col = col1 + x; // add the center point
        row = yc + y;   // add the center point
        // check for valid 640x480
        if (col > 639)
            col = 639;
        if (row > 479)
            row = 479;
        if (col < 0)
            col = 0;
        if (row < 0)
            row = 0;
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10) + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
        // left edge
        col = -col1 + x; // add the center point
        // check for valid 640x480
        if (col > 639)
            col = 639;
        if (row > 479)
            row = 479;
        if (col < 0)
            col = 0;
        if (row < 0)
            row = 0;
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10) + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
    }
    for (xc = -r; xc <= r; xc++)
    {
        // row = yc;
        row1 = (int)sqrt((float)(rsqr + r - xc * xc));
        // right edge
        col = xc + x;   // add the center point
        row = row1 + y; // add the center point
        // check for valid 640x480
        if (col > 639)
            col = 639;
        if (row > 479)
            row = 479;
        if (col < 0)
            col = 0;
        if (row < 0)
            row = 0;
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10) + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
        // left edge
        row = -row1 + y; // add the center point
        // check for valid 640x480
        if (col > 639)
            col = 639;
        if (row > 479)
            row = 479;
        if (col < 0)
            col = 0;
        if (row < 0)
            row = 0;
        // pixel_ptr = (char *)vga_pixel_ptr + (row<<10) + col ;
        //  set pixel color
        //*(char *)pixel_ptr = pixel_color;
        VGA_PIXEL(col, row, pixel_color);
    }
}

// =============================================
// === Draw a line
// =============================================
// plot a line
// at x1,y1 to x2,y2 with color
// Code is from David Rodgers,
//"Procedural Elements of Computer Graphics",1985
void VGA_line(int x1, int y1, int x2, int y2, short c)
{
    int e;
    signed int dx, dy, j, temp;
    signed int s1, s2, xchange;
    signed int x, y;
    char *pixel_ptr;

    /* check and fix line coordinates to be valid */
    if (x1 > 639)
        x1 = 639;
    if (y1 > 479)
        y1 = 479;
    if (x2 > 639)
        x2 = 639;
    if (y2 > 479)
        y2 = 479;
    if (x1 < 0)
        x1 = 0;
    if (y1 < 0)
        y1 = 0;
    if (x2 < 0)
        x2 = 0;
    if (y2 < 0)
        y2 = 0;

    x = x1;
    y = y1;

    // take absolute value
    if (x2 < x1)
    {
        dx = x1 - x2;
        s1 = -1;
    }

    else if (x2 == x1)
    {
        dx = 0;
        s1 = 0;
    }

    else
    {
        dx = x2 - x1;
        s1 = 1;
    }

    if (y2 < y1)
    {
        dy = y1 - y2;
        s2 = -1;
    }

    else if (y2 == y1)
    {
        dy = 0;
        s2 = 0;
    }

    else
    {
        dy = y2 - y1;
        s2 = 1;
    }

    xchange = 0;

    if (dy > dx)
    {
        temp = dx;
        dx = dy;
        dy = temp;
        xchange = 1;
    }

    e = ((int)dy << 1) - dx;

    for (j = 0; j <= dx; j++)
    {
        // video_pt(x,y,c); //640x480
        // pixel_ptr = (char *)vga_pixel_ptr + (y<<10)+ x;
        //  set pixel color
        //*(char *)pixel_ptr = c;
        VGA_PIXEL(x, y, c);

        if (e >= 0)
        {
            if (xchange == 1)
                x = x + s1;
            else
                y = y + s2;
            e = e - ((int)dx << 1);
        }

        if (xchange == 1)
            y = y + s2;
        else
            x = x + s1;

        e = e + ((int)dy << 1);
    }
}

uint8_t rgb565_to_rgb332(uint16_t pixel)
{
    uint8_t r5 = (pixel >> 11) & 0x1F;
    uint8_t g6 = (pixel >> 5) & 0x3F;
    uint8_t b5 = pixel & 0x1F;

    uint8_t r3 = (r5 * 7 + 15) / 31;
    uint8_t g3 = (g6 * 7 + 31) / 63;
    uint8_t b2 = (b5 * 3 + 15) / 31;

    return (r3 << 5) | (g3 << 2) | b2;
}

uint16_t rgb332_to_rgb565(uint8_t pixel)
{
    uint8_t r3 = (pixel >> 5) & 0x07;
    uint8_t g3 = (pixel >> 2) & 0x07;
    uint8_t b2 = pixel & 0x03;

    uint8_t r5 = (r3 * 31 + 3) / 7;
    uint8_t g6 = (g3 * 63 + 3) / 7;
    uint8_t b5 = (b2 * 31 + 1) / 3;

    return (r5 << 11) | (g6 << 5) | b5;
}

